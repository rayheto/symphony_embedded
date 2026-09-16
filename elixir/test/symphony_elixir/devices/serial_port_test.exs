defmodule SymphonyElixir.Devices.SerialPortTest do
  # The capture path runs a real helper process against a real PTY, so these
  # tests own the store and run synchronously. A PTY run is never a board run.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Devices.SerialPort
  alias SymphonyElixir.Experience.Store

  @peer Path.expand("../../support/pty_peer.py", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-serial-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    # `restart: :transient` lets one test take the store down deliberately
    # without the supervisor putting it straight back.
    start_supervised!(%{id: store, start: {Store, :start_link, [[name: store, data_root: root]]}, restart: :transient})

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, store: store}
  end

  defp open_peer do
    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stream,
        line: 4096,
        args: [@peer]
      ])

    path = wait_for_port(port)
    %{port: port, path: path}
  end

  defp wait_for_port(port, timeout \\ 5_000) do
    started = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, {:eol, "PORT " <> path}}} -> String.trim(path)
      {^port, {:data, {:noeol, "PORT " <> path}}} -> String.trim(path)
    after
      timeout - (System.monotonic_time(:millisecond) - started) -> flunk("PTY peer did not report a port")
    end
  end

  defp peer_write(%{port: port}, bytes) do
    Port.command(port, ["write ", Base.encode64(bytes), "\n"])
    await_peer_ok(port)
  end

  defp peer_close(%{port: port}) do
    Port.command(port, "close\n")
    await_peer_ok(port)
  end

  defp peer_quit(%{port: port}) do
    Port.command(port, "quit\n")
  end

  defp await_peer_ok(port) do
    receive do
      {^port, {:data, {:eol, "OK"}}} -> :ok
      {^port, {:data, {:noeol, "OK"}}} -> :ok
    after
      5_000 -> flunk("PTY peer did not acknowledge")
    end
  end

  defp start_capture(context, opts \\ []) do
    peer = open_peer()

    pid =
      start_supervised!(%{
        id: :serial_port,
        start:
          {SerialPort, :start_link,
           [
             [
               port: peer.path,
               session_id: "pty-test-1",
               project_id: "embedded-lab-demo",
               store: context.store,
               # Notifications go to the test process, not to the supervised child.
               owner: self()
             ]
             |> Keyword.merge(opts)
           ]},
        restart: :transient
      })

    {:ok, _session_id} = SerialPort.open(server: pid)

    %{peer: peer, port: pid}
  end

  defp await_status(server, status, timeout \\ 2_000) do
    started = System.monotonic_time(:millisecond)

    receive do
      {:serial, {:state, ^status, detail}} ->
        {:ok, detail}
    after
      timeout - (System.monotonic_time(:millisecond) - started) ->
        flunk("capture did not reach #{inspect(status)}; current: #{inspect(SerialPort.status(server))}")
    end
  end

  describe "capture" do
    test "keeps the exact bytes it read and commits them as a chunk", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      bytes = <<0x00, 0xFF, 0x41, 0x0A, 0xE4, 0xB8, 0xAD>>
      peer_write(peer, bytes)

      Process.sleep(200)
      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)

      assert [chunk] = SerialPort.chunks(server)
      assert chunk["size_bytes"] == byte_size(bytes)
      assert chunk["source_seq_start"] >= 1
      assert chunk["source_seq_end"] >= chunk["source_seq_start"]

      assert {:ok, stored} = Store.get_blob("embedded-lab-demo", chunk["blob_sha256"], server: context.store)
      assert stored == bytes

      peer_quit(peer)
    end

    test "reports invalid UTF-8 as a flag rather than losing the bytes", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      peer_write(peer, <<0xFF, 0xFE, 0x0A>>)
      Process.sleep(200)

      rows = SerialPort.recent(server)
      assert rows != []

      assert Enum.any?(rows, fn row ->
               row["invalid_utf8"] and is_binary(row["display_text"]) and row["display_text"] != ""
             end)

      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)
      peer_quit(peer)
    end

    test "splits a burst into ordered frames with monotonic sequence numbers", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      burst = :binary.copy("0123456789", 3_000)
      peer_write(peer, burst)
      Process.sleep(600)

      rows = SerialPort.recent(server)
      seqs = Enum.map(rows, & &1["source_seq"])
      assert seqs == Enum.sort(seqs)
      assert length(Enum.uniq(seqs)) == length(seqs)

      status = SerialPort.status(server)
      assert is_integer(status.last_source_seq)

      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)
      peer_quit(peer)
    end

    test "reports a disconnect when the device disappears", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      peer_write(peer, "boot ok\n")
      Process.sleep(200)
      peer_close(peer)

      assert {:ok, detail} = await_status(server, :disconnected, 5_000)

      assert detail != ""
      assert SerialPort.status(server).status == :disconnected
      peer_quit(peer)
    end

    test "refuses to open a port twice on one session", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      assert {:error, :already_capturing, %{session_id: "pty-test-1"}} = SerialPort.open(server: server)

      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)
      peer_quit(peer)
    end
  end

  describe "protocol frames" do
    # The frame shapes are the contract in `contracts/device-frame.schema.json`;
    # replaying them directly checks the decoder without inventing a device.
    defp helper_ref(server) do
      :sys.get_state(server).helper_port
    end

    defp feed(server, frame) do
      send(server, {helper_ref(server), {:data, {:eol, Jason.encode!(frame)}}})
      Process.sleep(50)
    end

    test "records a gap the helper reports and tells the owner", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, %{
        "kind" => "gap",
        "session_id" => "pty-test-1",
        "source_seq" => 5,
        "received_at" => "2026-09-14T10:38:00Z",
        "monotonic_ns" => 1_000,
        "from_seq" => 2,
        "to_seq" => 4,
        "reason" => "driver overflow"
      })

      assert_receive {:serial, {:gap, "driver overflow", 2, 4}}
      assert [%{reason: "driver overflow", from_seq: 2, to_seq: 4}] = SerialPort.status(server).gaps

      peer_quit(peer)
    end

    test "records a gap when the helper skips a source_seq", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, data_frame(1, "one"))
      feed(server, data_frame(4, "four"))
      assert_receive {:serial, {:gap, "source_seq skip", 2, 3}}

      peer_quit(peer)
    end

    test "reports an error state instead of a silent success", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, %{
        "kind" => "state",
        "session_id" => "pty-test-1",
        "source_seq" => 2,
        "received_at" => "2026-09-14T10:38:00Z",
        "monotonic_ns" => 2_000,
        "state" => "error",
        "detail" => "driver failed"
      })

      assert_receive {:serial, {:state, :error, "driver failed"}}
      assert SerialPort.status(server).status == :error

      peer_quit(peer)
    end

    test "reports an undecodable payload as a protocol error", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, %{
        "kind" => "data",
        "session_id" => "pty-test-1",
        "source_seq" => 1,
        "received_at" => "2026-09-14T10:38:00Z",
        "monotonic_ns" => 1_000,
        "payload_base64" => "not base64!!"
      })

      assert_receive {:serial, {:state, :error, detail}}, 500
      assert detail =~ "protocol error"

      peer_quit(peer)
    end

    test "handles a line the port delivers without a terminator", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      line =
        Jason.encode!(%{"kind" => "gap", "session_id" => "pty-test-1", "source_seq" => 3, "received_at" => "t", "monotonic_ns" => 1, "from_seq" => nil, "to_seq" => nil, "reason" => "no terminator"})

      send(server, {helper_ref(server), {:data, {:noeol, line}}})

      assert_receive {:serial, {:gap, "no terminator", nil, nil}}, 500
      peer_quit(peer)
    end

    test "treats an undecodable line or frame as a protocol error", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      send(server, {helper_ref(server), {:data, {:eol, "not json"}}})
      assert_receive {:serial, {:state, :error, _}}, 500

      # The helper is replaced by a fresh capture for the second case, because
      # the first one has already stopped.
      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)
      peer_quit(peer)
    end

    test "ignores a frame kind it does not know", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, %{"kind" => "telemetry", "detail" => "unused"})
      assert SerialPort.status(server).status == :capturing

      peer_quit(peer)
    end

    test "reports a helper that exits as a disconnect with a gap", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      send(server, {helper_ref(server), {:exit_status, 9}})
      assert_receive {:serial, {:state, :disconnected, detail}}, 500

      assert detail =~ "status 9"
      assert SerialPort.status(server).status == :disconnected
      assert [%{reason: reason}] = SerialPort.status(server).gaps
      assert reason =~ "exited"

      peer_quit(peer)
    end

    test "reports a chunk it could not commit instead of dropping the bytes", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      feed(server, data_frame(1, "bytes"))

      # The durable store goes away mid-capture; the bytes must not vanish
      # silently, and the capture must survive the outage.
      GenServer.stop(context.store)

      SerialPort.close(server)
      assert_receive {:serial, {:gap, "chunk commit failed", _, _}}, 1_000
      assert SerialPort.chunks(server) == []
      assert Enum.any?(SerialPort.status(server).gaps, &(&1.reason =~ "chunk commit failed"))

      peer_quit(peer)
    end

    defp data_frame(seq, text) do
      %{
        "kind" => "data",
        "session_id" => "pty-test-1",
        "source_seq" => seq,
        "received_at" => "2026-09-14T10:38:00Z",
        "monotonic_ns" => seq * 1_000,
        "payload_base64" => Base.encode64(text)
      }
    end
  end

  describe "control" do
    test "writes bytes to the device only while capturing", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      assert :ok = SerialPort.write(server, "hello\n")

      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)

      # A clean close is recorded as closed, which is a different fact from a
      # device that went away.
      assert {:error, :no_capture_session, %{status: :closed}} = SerialPort.write(server, "hello\n")
      peer_quit(peer)
    end

    test "reports a port it cannot open instead of a fake session", context do
      pid =
        start_supervised!(%{
          id: :bad_serial_port,
          start: {SerialPort, :start_link, [[port: "/dev/symphony-does-not-exist", session_id: "s-1", project_id: "p", store: context.store]]},
          restart: :transient
        })

      assert {:error, :port_open_failed, %{port: "/dev/symphony-does-not-exist"}} = SerialPort.open(server: pid)
      assert SerialPort.status(pid).status == :error
    end

    test "commits a chunk that has been open long enough", context do
      %{peer: peer, port: server} = start_capture(context, chunk_max_age_ms: 50)
      assert {:ok, _detail} = await_status(server, :connected)

      peer_write(peer, "slow trickle\n")

      assert_receive {:serial, {:chunk, chunk}}, 2_000
      assert chunk["size_bytes"] > 0

      peer_quit(peer)
    end

    test "uses the configured interpreter name", context do
      pid =
        start_supervised!(%{
          id: :named_python_serial_port,
          start:
            {SerialPort, :start_link,
             [
               [
                 port: "/dev/symphony-does-not-exist",
                 session_id: "s-named",
                 project_id: "embedded-lab-demo",
                 store: context.store,
                 owner: self(),
                 python: "python3"
               ]
             ]},
          restart: :transient
        })

      assert {:error, :port_open_failed, _} = SerialPort.open(server: pid)
    end

    test "reports a host with no interpreter at all", context do
      # The helper is launched by absolute path, so a host without python3 on
      # its PATH must be reported rather than producing a broken session.
      original = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-symphony-path")
      on_exit(fn -> System.put_env("PATH", original) end)

      pid =
        start_supervised!(%{
          id: :no_interpreter_serial_port,
          start:
            {SerialPort, :start_link,
             [
               [
                 port: "/dev/symphony-any",
                 session_id: "s-no-python",
                 project_id: "embedded-lab-demo",
                 store: context.store,
                 owner: self()
               ]
             ]},
          restart: :transient
        })

      assert {:error, :python_unavailable, %{reason: reason}} = SerialPort.open(server: pid)
      assert reason =~ "python3"
    end

    test "reports a helper it cannot start at all", context do
      pid =
        start_supervised!(%{
          id: :broken_python_serial_port,
          start:
            {SerialPort, :start_link,
             [
               [
                 port: "/dev/symphony-any",
                 session_id: "s-broken",
                 project_id: "embedded-lab-demo",
                 store: context.store,
                 owner: self(),
                 python: "/nonexistent/interpreter"
               ]
             ]},
          restart: :transient
        })

      assert {:error, :helper_start_failed, %{reason: _}} = SerialPort.open(server: pid)
    end

    test "closes and pings a capture that never opened a port", context do
      pid =
        start_supervised!(%{
          id: :idle_serial_port,
          start: {SerialPort, :start_link, [[port: "/dev/symphony-idle", session_id: "s-idle", project_id: "embedded-lab-demo", store: context.store, owner: self()]]},
          restart: :transient
        })

      assert :ok = SerialPort.close(pid)
      assert SerialPort.status(pid).status == :idle

      send(pid, {:open_timeout, "open-s-idle"})
      send(pid, {:open_timeout, "open-unknown"})
      send(pid, :chunk_tick)
      send(pid, :unrelated)

      assert SerialPort.status(pid).status == :idle
    end

    test "times out instead of reporting a session that never opened", context do
      slow = Path.expand("../../support/silent_executable.sh", __DIR__)

      pid =
        start_supervised!(%{
          id: :slow_serial_port,
          start:
            {SerialPort, :start_link,
             [
               [
                 port: "/dev/symphony-slowed",
                 session_id: "s-slow",
                 project_id: "embedded-lab-demo",
                 store: context.store,
                 owner: self(),
                 python: slow
               ]
             ]},
          restart: :transient
        })

      assert {:error, :helper_timeout, %{port: "/dev/symphony-slowed"}} = SerialPort.open(server: pid)
      assert SerialPort.status(pid).status == :error
    end

    test "reports a missing interpreter rather than a broken session", context do
      pid =
        start_supervised!(%{
          id: :no_python_serial_port,
          start:
            {SerialPort, :start_link,
             [
               [
                 port: "/dev/symphony-any",
                 session_id: "s-none",
                 project_id: "embedded-lab-demo",
                 store: context.store,
                 owner: self(),
                 python: nil
               ]
             ]},
          restart: :transient
        })

      assert {:error, code, _details} = SerialPort.open(server: pid)
      assert code in [:helper_start_failed, :python_unavailable, :port_open_failed]
      assert SerialPort.status(pid).status == :error
    end

    test "keeps an idle session from producing empty chunks", context do
      %{peer: peer, port: server} = start_capture(context)
      assert {:ok, _detail} = await_status(server, :connected)

      SerialPort.close(server)
      assert {:ok, _detail} = await_status(server, :closed)

      assert SerialPort.chunks(server) == []
      peer_quit(peer)
    end
  end
end
