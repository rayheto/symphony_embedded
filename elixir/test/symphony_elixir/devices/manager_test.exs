defmodule SymphonyElixir.Devices.ManagerTest do
  # The manager owns a real helper process for the capture test, so this module
  # runs synchronously.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Devices.{Config, Manager}
  alias SymphonyElixir.Experience.Store

  @peer Path.expand("../../support/pty_peer.py", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-devices-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!(%{id: store, start: {Store, :start_link, [[name: store, data_root: root]]}, restart: :transient})

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, store: store}
  end

  defp device_config(path, device_overrides) do
    File.write!(path, """
    schema_version: "1.0"
    host_id: "test-host"
    serial:
      baudrate: 115200
      read_timeout_ms: 50
    devices:
      - key: "board-a"
        display_name: "开发板 A"
        adapter: "serial"
        port: #{Map.get(device_overrides, :port, "\"/dev/symphony-does-not-exist\"")}
        hardware_revision: "rev A"
        action_ids: ["reboot"]
      - key: "board-b"
        display_name: "备用开发板"
        adapter: "serial"
        action_ids: []
    actions:
      - tool_id: "reboot"
        absolute_executable: "/bin/echo"
        fixed_argv_template: ["rebooting"]
        timeout_ms: 5000
        required_capability: "control"
        idempotent: true
    image_sources: []
    decoders: []
    """)
  end

  defp start_manager(context, opts \\ []) do
    File.mkdir_p!(context.root)
    path = Path.join(context.root, "devices.yaml")
    device_config(path, Keyword.get(opts, :device, %{}))

    path = Keyword.get(opts, :path, path)

    name = Module.concat(__MODULE__, :"Manager#{System.unique_integer([:positive])}")

    manager_opts = [name: name, config_path: path] ++ Keyword.take(opts, [:max_sessions])

    start_supervised!(%{id: name, start: {Manager, :start_link, [manager_opts]}})
    name
  end

  describe "config" do
    test "reports a missing inventory without failing to start", %{root: root} do
      missing = Path.join(root, "no-such-file.yaml")

      assert {:ok, settings} = Config.load(missing)
      assert settings.devices == []
      assert [limitation] = settings.limitations
      assert limitation =~ "不存在"

      assert {:ok, empty} = Config.load(nil)
      assert empty.host_id == "unknown-host"
    end

    test "rejects a config that is not a mapping or carries no version", %{root: root} do
      listed = Path.join(root, "list.yaml")
      File.write!(listed, "- not\n- a mapping\n")
      assert {:error, :device_config_invalid, %{reason: "not a mapping"}} = Config.load(listed)

      unversioned = Path.join(root, "unversioned.yaml")
      File.write!(unversioned, "host_id: \"somewhere\"\n")
      assert {:error, :device_config_invalid, %{reason: reason}} = Config.load(unversioned)
      assert reason =~ "schema_version"
    end

    test "keeps a numeric argument template readable", %{root: root} do
      path = Path.join(root, "numeric-argv.yaml")

      File.write!(path, """
      schema_version: "1.0"
      host_id: "test-host"
      actions:
        - tool_id: "set-baud"
          absolute_executable: "/bin/echo"
          fixed_argv_template: [115200]
          required_capability: "control"
      """)

      assert {:ok, settings} = Config.load(path)
      assert hd(settings.actions).argv == ["115200"]

      decoded = Path.join(root, "numeric-decoder-argv.yaml")

      File.write!(decoded, """
      schema_version: "1.0"
      decoders:
        - key: "arm"
          absolute_executable: "/usr/bin/true"
          fixed_argv_template: [115200]
      """)

      assert {:ok, settings} = Config.load(decoded)
      assert hd(settings.decoders).argv == ["115200"]
    end

    test "rejects a config it cannot read or version", %{root: root} do
      broken = Path.join(root, "broken.yaml")
      File.write!(broken, "schema_version: \"1.0\"\n  bad: indent\n")
      assert {:error, :device_config_invalid, %{path: ^broken}} = Config.load(broken)

      future = Path.join(root, "future.yaml")
      File.write!(future, "schema_version: \"9.9\"\n")
      assert {:error, :unsupported_device_config_version, %{supported: "1.0"}} = Config.load(future)

      unreadable = Path.join(root, "unreadable.yaml")
      File.mkdir_p!(unreadable)
      assert {:error, :device_config_unreadable, _} = Config.load(unreadable)
    end

    test "parses devices, actions, image sources and decoders", %{root: root} do
      path = Path.join(root, "devices.yaml")

      File.write!(path, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
          hardware_revision: "rev A"
          action_ids: ["reboot"]
        - key: "board-b"
          display_name: "备用开发板"
          action_ids: []
      actions:
        - tool_id: "reboot"
          absolute_executable: "/bin/echo"
          fixed_argv_template: ["rebooting"]
      image_sources:
        - key: "uvc"
          label: "固定相机"
      decoders:
        - key: "arm"
          display_name: "ARM 栈"
          absolute_executable: "/usr/bin/true"
      """)

      assert {:ok, settings} = Config.load(path)

      assert settings.host_id == "test-host"
      assert Enum.map(settings.devices, & &1.key) == ["board-a", "board-b"]
      assert Enum.map(settings.actions, & &1.tool_id) == ["reboot"]
      assert Enum.map(settings.image_sources, & &1.key) == ["uvc"]
      assert Enum.map(settings.decoders, & &1.key) == ["arm"]

      board = Enum.find(settings.devices, &(&1.key == "board-a"))
      assert board.display_name == "开发板 A"
      assert board.hardware_revision == "rev A"
      assert Enum.map(board.actions, & &1.tool_id) == ["reboot"]
      assert hd(board.actions).argv == ["rebooting"]
    end
  end

  describe "default arity" do
    test "the manager answers through its own registered name", context do
      if pid = Process.whereis(Manager), do: GenServer.stop(pid)

      path = Path.join(context.root, "default-arity.yaml")
      File.mkdir_p!(context.root)
      device_config(path, %{})

      start_supervised!(%{id: Manager, start: {Manager, :start_link, [[config_path: path]]}})

      on_exit(fn -> if pid = Process.whereis(Manager), do: GenServer.stop(pid) end)

      assert [device | _] = Manager.list()
      assert device["id"] == "board-a"
      assert {:ok, _} = Manager.get("board-a")
      assert {:ok, _} = Manager.probe("board-a")
      assert Manager.sessions() == []

      {:ok, lease} = Manager.acquire_lease("board-a", "run-1")
      assert {:ok, _} = Manager.renew_lease("board-a", "run-1", lease["generation"])
      assert {:ok, _} = Manager.release_lease("board-a", "run-1", lease["generation"])
      assert {:error, _code, _details} = Manager.run_action("board-a", "reboot", "run-1", 1)
      assert {:error, :no_capture_session, _} = Manager.close_capture("board-b")
    end

    test "starts under its own registered name" do
      if pid = Process.whereis(Manager), do: GenServer.stop(pid)

      assert {:ok, pid} = Manager.start_link()
      assert is_pid(pid)
      GenServer.stop(pid)
    end
  end

  describe "registry" do
    test "lists registered devices with their capabilities", context do
      manager = start_manager(context)

      assert [board_a, board_b] = Manager.list(manager)
      assert board_a["id"] == "board-a"
      assert board_a["connection_status"] == "unknown"
      assert board_a["active_session_id"] == nil
      assert board_a["lease"] == nil

      capabilities = Map.new(board_a["capabilities"], &{&1.name, &1})
      assert capabilities["read"].available
      assert capabilities["capture"].available
      assert capabilities["control"].available

      # A device with no allowlisted action says why instead of offering one.
      spare = Map.new(board_b["capabilities"], &{&1.name, &1})
      refute spare["control"].available
      assert spare["control"].reason =~ "allowlisted"
      refute spare["capture"].available
    end

    test "reports an unknown device instead of inventing one", context do
      manager = start_manager(context)

      assert {:error, :unknown_device, %{device_key: "ghost"}} = Manager.get(manager, "ghost")
      assert {:error, :unknown_device, _} = Manager.probe(manager, "ghost")
      assert {:error, :unknown_device, _} = Manager.close_capture(manager, "ghost")

      assert {:ok, device} = Manager.get(manager, "board-a")
      assert device["display_name"] == "开发板 A"
    end

    test "probes the port rather than trusting the configuration", context do
      manager = start_manager(context)

      assert {:ok, probe} = Manager.probe(manager, "board-a")
      assert probe["port_present"] == false
      assert probe["connection_status"] == "offline"
      assert probe["limitations"] != []

      # A registered port that exists is reported online.
      file = Path.join(context.root, "fake-port")
      File.write!(file, "")
      online = start_manager(%{context | root: Path.join(context.root, "second")}, device: %{port: "\"#{file}\""})

      assert {:ok, online_probe} = Manager.probe(online, "board-a")
      assert online_probe["port_present"] == true
      assert online_probe["connection_status"] == "online"
    end

    test "keeps a missing inventory from breaking the manager" do
      name = Module.concat(__MODULE__, :"Empty#{System.unique_integer([:positive])}")
      path = Path.join(System.tmp_dir!(), "symphony-absent-#{System.unique_integer([:positive])}.yaml")

      start_supervised!(%{id: name, start: {Manager, :start_link, [[name: name, config_path: path]]}})

      assert Manager.list(name) == []
      assert {:error, :unknown_device, _} = Manager.get(name, "board-a")

      send(name, {:serial, {:data, "ignored"}})
      send(name, :unrelated)
      assert Manager.list(name) == []

      assert {:ok, pid} = Manager.start_link(name: Module.concat(__MODULE__, :"Bare#{System.unique_integer([:positive])}"))
      assert is_pid(pid)
    end

    test "starts with the empty inventory when the config cannot be read", %{root: root} do
      broken = Path.join(root, "bad-version.yaml")
      File.write!(broken, "schema_version: \"9.9\"\n")

      name = Module.concat(__MODULE__, :"BadConfig#{System.unique_integer([:positive])}")
      start_supervised!(%{id: name, start: {Manager, :start_link, [[name: name, config_path: broken]]}})

      assert Manager.list(name) == []
    end
  end

  describe "leases" do
    test "hands out an increasing generation and refuses a competing owner", context do
      manager = start_manager(context)

      assert {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")
      assert lease["generation"] == 1
      assert lease["owner_run_id"] == "run-1"
      assert lease["status"] == "active"
      assert lease["ttl_seconds"] == 30

      assert {:error, :lease_held, %{owner_run_id: "run-1", generation: 1}} =
               Manager.acquire_lease(manager, "board-a", "run-2")

      # The same owner may take it again while its lease is active.
      assert {:ok, same} = Manager.acquire_lease(manager, "board-a", "run-1")
      assert same["generation"] == 2
    end

    test "renews only the deadline, and only for the current holder", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1", ttl_seconds: 10)

      assert {:ok, renewed} = Manager.renew_lease(manager, "board-a", "run-1", lease["generation"], ttl_seconds: 60)
      assert renewed["generation"] == lease["generation"]
      assert renewed["owner_run_id"] == "run-1"
      assert renewed["expires_at"] >= lease["expires_at"]

      assert {:error, :lease_mismatch, %{held_by: "run-1"}} =
               Manager.renew_lease(manager, "board-a", "run-2", lease["generation"])

      assert {:error, :lease_mismatch, %{held_generation: 1}} =
               Manager.renew_lease(manager, "board-a", "run-1", 99)
    end

    test "refuses an expired lease instead of renewing it back to life", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1", ttl_seconds: 5)

      # The deadline passes: the token is dead even though the record remains.
      expire_lease(manager, "board-a")

      assert {:error, :lease_expired, _} = Manager.renew_lease(manager, "board-a", "run-1", lease["generation"])

      assert {:error, :lease_expired, _} =
               Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])

      # The next acquisition is a new generation, so the old token stays refused.
      assert {:ok, next} = Manager.acquire_lease(manager, "board-a", "run-2")
      assert next["generation"] == 2

      assert {:error, :lease_mismatch, _} = Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])
    end

    test "releases a lease and refuses an unknown one", context do
      manager = start_manager(context)

      assert {:error, :no_lease, _} = Manager.release_lease(manager, "board-a", "run-1", 1)

      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")
      assert {:ok, released} = Manager.release_lease(manager, "board-a", "run-1", lease["generation"])
      assert released["status"] == "released"

      assert {:ok, device} = Manager.get(manager, "board-a")
      assert device["lease"] == nil
    end

    test "refuses a lease duration outside the documented range", context do
      manager = start_manager(context)

      assert {:error, :invalid_lease_ttl, %{min: 5, max: 300}} =
               Manager.acquire_lease(manager, "board-a", "run-1", ttl_seconds: 1)

      assert {:error, :invalid_lease_ttl, _} = Manager.acquire_lease(manager, "board-a", "run-1", ttl_seconds: "soon")
    end

    test "answers for a device with a malformed lease timestamp", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      :sys.replace_state(manager, fn state ->
        device = Map.fetch!(state.devices, "board-a")
        broken = %{device.lease | expires_at: "not-a-time"}
        %{state | devices: Map.put(state.devices, "board-a", Map.put(device, :lease, broken))}
      end)

      assert {:error, :lease_expired, %{expires_at: "not-a-time"}} =
               Manager.renew_lease(manager, "board-a", "run-1", lease["generation"])

      # An unreadable deadline is treated as expired, so a new holder can take
      # over rather than being blocked forever.
      assert {:ok, next} = Manager.acquire_lease(manager, "board-a", "run-2")
      assert next["generation"] == 2
    end

    test "refuses a lease on a device that is not registered", context do
      manager = start_manager(context)

      assert {:error, :unknown_device, _} = Manager.acquire_lease(manager, "ghost", "run-1")
    end

    defp expire_lease(manager, device_key) do
      :sys.replace_state(manager, fn state ->
        device = Map.fetch!(state.devices, device_key)
        expired = %{device.lease | expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()}

        %{state | devices: Map.put(state.devices, device_key, Map.put(device, :lease, expired))}
      end)
    end
  end

  describe "actions" do
    test "runs a registered action under the current lease", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      assert {:ok, receipt} =
               Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])

      assert receipt["exit_code"] == 0
      assert receipt["executable"] == "/bin/echo"
      assert receipt["argv"] == ["rebooting"]
      assert receipt["output_bytes"] > 0
      assert String.length(receipt["output_sha256"]) == 64
      assert receipt["limitations"] == []
      assert receipt["started_at"] =~ "T"
    end

    test "refuses an action the host never registered", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      assert {:error, :unknown_action, %{known: ["reboot"]}} =
               Manager.run_action(manager, "board-a", "flash", "run-1", lease["generation"])
    end

    test "refuses a control action without a lease", context do
      manager = start_manager(context)

      assert {:error, :no_lease, %{device_key: "board-a"}} =
               Manager.run_action(manager, "board-a", "reboot", "run-1", 1)
    end

    test "reports an action the host left half-configured", context do
      manager = start_manager(context)

      :sys.replace_state(manager, fn state ->
        action = hd(state.config.actions)
        %{state | config: %{state.config | actions: [%{action | executable: nil}]}}
      end)

      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      assert {:error, :action_not_configured, %{tool_id: "reboot"}} =
               Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])
    end

    test "reports an executable the host cannot run", context do
      manager = start_manager(context)
      directory = Path.join(context.root, "not-a-binary")
      File.mkdir_p!(directory)

      :sys.replace_state(manager, fn state ->
        action = hd(state.config.actions)
        %{state | config: %{state.config | actions: [%{action | executable: directory, argv: []}]}}
      end)

      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      assert {:ok, receipt} = Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])
      assert receipt["exit_code"] != 0
      assert receipt["limitations"] != []
    end

    test "reports a registered action whose executable is gone", context do
      manager = start_manager(context, device: %{port: "\"/dev/symphony-does-not-exist\""})

      :sys.replace_state(manager, fn state ->
        action = hd(state.config.actions)
        %{state | config: %{state.config | actions: [%{action | executable: "/nonexistent/tool"}]}}
      end)

      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      # A host tool that has gone missing is reported through the receipt.
      assert {:ok, receipt} = Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])
      assert receipt["exit_code"] == 127
      assert receipt["limitations"] != []
    end

    test "reports a non-zero exit as a limitation rather than a success", context do
      manager = start_manager(context)

      :sys.replace_state(manager, fn state ->
        action = hd(state.config.actions)
        %{state | config: %{state.config | actions: [%{action | executable: "/bin/false", argv: []}]}}
      end)

      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      assert {:ok, receipt} = Manager.run_action(manager, "board-a", "reboot", "run-1", lease["generation"])
      assert receipt["exit_code"] != 0
      assert receipt["limitations"] != []
    end
  end

  describe "capture" do
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

      %{port: port, path: wait_for_port(port)}
    end

    defp wait_for_port(port) do
      receive do
        {^port, {:data, {:eol, "PORT " <> path}}} -> String.trim(path)
        {^port, {:data, {:noeol, "PORT " <> path}}} -> String.trim(path)
      after
        5_000 -> flunk("PTY peer did not report a port")
      end
    end

    test "opens a capture session and refuses a second owner", context do
      peer = open_peer()

      manager =
        start_manager(%{context | root: Path.join(context.root, "capture")},
          device: %{port: "\"#{peer.path}\""}
        )

      assert {:ok, session} = Manager.open_capture(manager, "board-a", project_id: "embedded-lab-demo", store: context.store, owner: self())
      assert session["session_id"] =~ "capture-"
      assert session["device_id"] == "board-a"

      assert {:ok, device} = Manager.get(manager, "board-a")
      assert device["active_session_id"] == session["session_id"]

      assert {:error, :port_owned, %{session_id: _}} = Manager.open_capture(manager, "board-a")

      assert Manager.sessions(manager) |> length() == 1
      assert Manager.sessions(manager, "board-a") |> length() == 1
      assert Manager.sessions(manager, "board-b") == []

      assert {:ok, closed} = Manager.close_capture(manager, "board-a")
      assert closed["status"] == "closing"

      assert {:error, :no_capture_session, _} = Manager.close_capture(manager, "board-a")

      Port.command(peer.port, "quit\n")
    end

    test "refuses a capture on a device without a port", context do
      manager = start_manager(context)

      assert {:error, :device_has_no_port, %{device_key: "board-b"}} =
               Manager.open_capture(manager, "board-b", project_id: "p", store: context.store)
    end

    test "allows a capture while a live lease is held", context do
      manager = start_manager(context)
      {:ok, _lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      # A live lease must not block the port the same run already owns.
      assert {:error, :port_open_failed, _} =
               Manager.open_capture(manager, "board-a", project_id: "p", store: context.store, owner: self())
    end

    test "reports a device whose serial settings are not a mapping", context do
      manager = start_manager(context)

      :sys.replace_state(manager, fn state ->
        device = Map.fetch!(state.devices, "board-a")
        %{state | devices: Map.put(state.devices, "board-a", Map.put(device, :serial, "115200"))}
      end)

      assert {:error, :port_open_failed, _} =
               Manager.open_capture(manager, "board-a", project_id: "p", store: context.store, owner: self())
    end

    test "refuses a capture while a stale lease still holds the device", context do
      manager = start_manager(context)
      {:ok, lease} = Manager.acquire_lease(manager, "board-a", "run-1")

      :sys.replace_state(manager, fn state ->
        device = Map.fetch!(state.devices, "board-a")
        expired = %{device.lease | expires_at: DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()}
        %{state | devices: Map.put(state.devices, "board-a", Map.put(device, :lease, expired))}
      end)

      # A stale lease is reported rather than silently ignored.
      assert {:error, :lease_expired, _} =
               Manager.open_capture(manager, "board-a", project_id: "p", store: context.store)

      assert lease["generation"] == 1
    end

    test "reports a host that is already at its capture limit", context do
      peer = open_peer()

      manager =
        start_manager(%{context | root: Path.join(context.root, "limited")},
          device: %{port: ~s("#{peer.path}")},
          max_sessions: 0
        )

      assert {:error, :session_start_failed, %{reason: reason}} =
               Manager.open_capture(manager, "board-a", project_id: "p", store: context.store, owner: self())

      assert reason =~ "max_children"

      Port.command(peer.port, "quit\n")
    end

    test "reports the session it cannot open instead of keeping it", context do
      manager = start_manager(context)

      assert {:error, :port_open_failed, _} =
               Manager.open_capture(manager, "board-a", project_id: "p", store: context.store, owner: self())

      assert {:ok, device} = Manager.get(manager, "board-a")
      assert device["active_session_id"] == nil
      assert Manager.sessions(manager) == []
    end
  end
end
