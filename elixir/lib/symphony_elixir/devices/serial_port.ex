defmodule SymphonyElixir.Devices.SerialPort do
  @moduledoc """
  Owns one `serial_helper.py` Port and turns its JSONL frames into evidence.

  The helper is the only process that touches the port, so two readers can never
  race for the same device. Raw bytes are kept as they arrived: a chunk is
  committed to the content-addressed store with its byte range and sequence
  range, and the display text is derived later, never stored as the original.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Experience.Store

  @helper "serial_helper.py"
  @chunk_max_bytes 8 * 1024 * 1024
  @chunk_max_age_ms 60_000
  @recent_limit 5_000
  # Data notifications are coalesced to this interval so a burst cannot flood
  # the page with one message per frame.
  @notice_interval_ms 100
  @default_timeout 10_000
  # Shorter than the caller's own timeout, so a silent helper produces a real
  # error rather than a bare GenServer.call exit.
  @open_timeout 8_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{}

    defstruct [
      :config,
      :port_name,
      :session_id,
      :device_id,
      :project_id,
      :store,
      :owner,
      :helper_port,
      :awaiting_open,
      :open_timer,
      :buffer,
      :buffer_bytes,
      :buffer_started_at,
      :buffer_first_seq,
      :last_source_seq,
      :chunks,
      :recent,
      :status,
      :gaps,
      :pending,
      :last_notice_ms,
      :pending_notice_seq
    ]
  end

  @type frame :: map()

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Captured here, where the caller is still current, so notifications reach
    # the process that started the capture rather than this GenServer itself.
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Open the configured port and start capturing.

  Returns `{:ok, session_id}` only once the helper reports the port connected,
  so a caller never records a session that does not exist.
  """
  @spec open(keyword()) :: {:ok, String.t()} | {:error, atom(), map()}
  def open(opts) do
    GenServer.call(Keyword.fetch!(opts, :server), {:open, opts}, @default_timeout)
  end

  @spec close(GenServer.server()) :: :ok | {:error, atom(), map()}
  def close(server), do: GenServer.call(server, :close, @default_timeout)

  @spec write(GenServer.server(), binary()) :: :ok | {:error, atom(), map()}
  def write(server, bytes), do: GenServer.call(server, {:write, bytes}, @default_timeout)

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status, @default_timeout)

  @doc "The committed chunks of this session, in order."
  @spec chunks(GenServer.server()) :: [map()]
  def chunks(server), do: GenServer.call(server, :chunks, @default_timeout)

  @doc "The recent rows kept in memory for the live view, newest last."
  @spec recent(GenServer.server(), pos_integer()) :: [map()]
  def recent(server, limit \\ 500), do: GenServer.call(server, {:recent, limit}, @default_timeout)

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    port_name = Keyword.fetch!(opts, :port)
    session_id = Keyword.fetch!(opts, :session_id)

    state = %State{
      config: opts,
      port_name: port_name,
      session_id: session_id,
      device_id: Keyword.get(opts, :device_id),
      project_id: Keyword.get(opts, :project_id),
      store: Keyword.get(opts, :store, Store),
      owner: Keyword.get(opts, :owner, self()),
      buffer: [],
      buffer_bytes: 0,
      chunks: [],
      recent: [],
      gaps: [],
      status: :idle,
      pending: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:open, opts}, from, state) do
    # Device settings come from the registered configuration; an explicit open
    # call may override them for one session.
    opts = Keyword.merge(state.config, opts)

    if state.status == :capturing do
      {:reply, {:error, :already_capturing, %{session_id: state.session_id}}, state}
    else
      case start_helper(state, opts) do
        {:ok, helper_port, awaiting} ->
          # The caller is only told the session exists once the helper confirms
          # the port is open, so no caller records a session that came up empty.
          timer = Process.send_after(self(), {:open_timeout, open_request_id(state)}, @open_timeout)

          {:noreply,
           %{
             state
             | helper_port: helper_port,
               status: :connecting,
               pending: awaiting,
               awaiting_open: from,
               open_timer: timer
           }}

        {:error, code, details} ->
          {:reply, {:error, code, details}, state}
      end
    end
  end

  def handle_call(:close, _from, state) do
    state = request_close(state)
    {:reply, :ok, state}
  end

  def handle_call({:write, bytes}, _from, state) do
    case state.status do
      :capturing ->
        request_id = "write-#{System.unique_integer([:positive])}"
        send_helper(state, %{"kind" => "request", "request_id" => request_id, "command" => "write", "payload" => %{"data_base64" => Base.encode64(bytes)}})
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :no_capture_session, %{status: state.status}}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       port: state.port_name,
       session_id: state.session_id,
       status: state.status,
       last_source_seq: state.last_source_seq,
       chunk_count: length(state.chunks),
       buffered_bytes: state.buffer_bytes,
       gaps: state.gaps
     }, state}
  end

  def handle_call(:chunks, _from, state), do: {:reply, Enum.reverse(state.chunks), state}

  def handle_call({:recent, limit}, _from, state) do
    # Newest first in memory, chronological to the caller.
    {:reply, state.recent |> Enum.take(limit) |> Enum.reverse(), state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{helper_port: port} = state) do
    {:noreply, handle_line(state, line)}
  end

  def handle_info({port, {:data, {:noeol, line}}}, %{helper_port: port} = state) do
    # The helper writes whole lines; a partial one is buffered by the port until
    # the newline arrives, and is only ever surfaced as a protocol error.
    {:noreply, handle_line(state, line)}
  end

  def handle_info({port, {:exit_status, status}}, %{helper_port: port} = state) do
    Logger.warning("serial helper for #{state.port_name} exited with status #{status}")

    state =
      state
      |> record_gap("serial helper exited before the capture was closed", nil, nil)
      |> Map.put(:status, :disconnected)
      |> Map.put(:helper_port, nil)
      |> commit_buffer()

    notify(state, {:serial, {:state, :disconnected, "helper exited with status #{status}"}})
    {:noreply, state}
  end

  def handle_info({:open_timeout, request_id}, %{open_timer: _timer} = state) do
    case Map.pop(state.pending, request_id) do
      {:open, pending} ->
        GenServer.reply(state.awaiting_open, {:error, :helper_timeout, %{port: state.port_name}})

        {:noreply, %{state | status: :error, pending: pending, awaiting_open: nil, open_timer: nil}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  # A quiet session must still split a chunk by age, so the tick closes an aged
  # chunk even when no further bytes arrive.
  def handle_info(:chunk_tick, %{status: :capturing} = state) do
    schedule_chunk_tick()
    {:noreply, state |> maybe_commit_chunk() |> flush_notice()}
  end

  def handle_info(:chunk_tick, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Helper lifecycle
  # ------------------------------------------------------------------

  defp start_helper(state, opts) do
    helper_path = Path.join(:code.priv_dir(:symphony_elixir), "device_helper/#{@helper}")

    # `spawn_executable` needs an absolute path, so the interpreter is resolved
    # once instead of relying on the shell's PATH.
    case python_interpreter(opts) do
      python when is_binary(python) ->
        open_helper_port(python, helper_path, state, opts)

      _missing ->
        {:error, :python_unavailable, %{reason: "python3 was not found on PATH"}}
    end
  rescue
    error -> {:error, :helper_start_failed, %{reason: Exception.message(error)}}
  end

  defp python_interpreter(opts) do
    case Keyword.get(opts, :python) do
      nil -> System.find_executable("python3")
      "python3" -> System.find_executable("python3")
      configured -> configured
    end
  end

  defp open_helper_port(python, helper_path, state, opts) do
    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stream,
        line: 96 * 1024,
        args: [helper_path]
      ])

    open_request = %{
      "kind" => "request",
      "request_id" => open_request_id(state),
      "command" => "open",
      "payload" => %{
        "session_id" => state.session_id,
        "port" => state.port_name,
        "baudrate" => opts |> Keyword.get(:baudrate, 115_200) |> to_string() |> String.to_integer(),
        "bytesize" => to_string(Keyword.get(opts, :bytesize, 8)),
        "parity" => to_string(Keyword.get(opts, :parity, "N")),
        "stopbits" => to_string(Keyword.get(opts, :stopbits, 1)),
        "read_timeout_ms" => Keyword.get(opts, :read_timeout_ms, 100)
      }
    }

    send_helper_port(port, open_request)
    {:ok, port, %{open_request_id(state) => :open}}
  end

  defp open_request_id(state), do: "open-#{state.session_id}"

  defp request_close(%{helper_port: nil} = state), do: state

  defp request_close(state) do
    request_id = "close-#{state.session_id}"

    send_helper(state, %{
      "kind" => "request",
      "request_id" => request_id,
      "command" => "close",
      "payload" => %{"session_id" => state.session_id}
    })

    %{state | status: :closing, pending: Map.put(state.pending, request_id, :close)}
  end

  defp send_helper(state, frame) do
    send_helper_port(state.helper_port, frame)
  end

  defp send_helper_port(port, frame) do
    Port.command(port, [Jason.encode!(frame), "\n"])
  end

  # ------------------------------------------------------------------
  # Frame handling
  # ------------------------------------------------------------------

  defp handle_line(state, line) do
    case Jason.decode(line) do
      {:ok, %{"kind" => "response"} = frame} -> handle_response(state, frame)
      {:ok, %{"kind" => "data"} = frame} -> handle_data(state, frame)
      {:ok, %{"kind" => "gap"} = frame} -> handle_gap(state, frame)
      {:ok, %{"kind" => "state"} = frame} -> handle_state(state, frame)
      {:ok, _unknown} -> state
      {:error, reason} -> handle_protocol_error(state, reason)
    end
  end

  defp handle_response(state, %{"request_id" => request_id, "status" => status} = frame) do
    case {Map.pop(state.pending, request_id), status} do
      {{:open, _pending}, "ok"} ->
        GenServer.reply(state.awaiting_open, {:ok, state.session_id})
        cancel_open_timer(state)
        schedule_chunk_tick()

        %{state | status: :capturing, buffer_started_at: now_ms(), awaiting_open: nil, open_timer: nil}

      {{:open, _pending}, "error"} ->
        Logger.error("serial open failed for #{state.port_name}: #{frame["error"]}")
        GenServer.reply(state.awaiting_open, {:error, :port_open_failed, %{port: state.port_name, reason: frame["error"]}})
        cancel_open_timer(state)

        %{state | status: :error, awaiting_open: nil, open_timer: nil}

      {{:close, _pending}, _status} ->
        state |> commit_buffer() |> Map.put(:status, :closed)

      {_other, _status} ->
        state
    end
  end

  @spec schedule_chunk_tick() :: reference()
  defp schedule_chunk_tick, do: Process.send_after(self(), :chunk_tick, 1_000)

  defp cancel_open_timer(%{open_timer: timer}) do
    Process.cancel_timer(timer)
    :ok
  end

  # Raw bytes stay raw: the frame is stored exactly as it arrived, and the
  # display text is derived from these bytes later.
  defp handle_data(state, %{"source_seq" => seq, "payload_base64" => encoded}) do
    case Base.decode64(encoded) do
      {:ok, bytes} ->
        state
        |> note_gap_before(seq)
        |> append(bytes, seq)
        |> Map.put(:last_source_seq, seq)
        |> maybe_commit_chunk()

      :error ->
        handle_protocol_error(state, :invalid_base64)
    end
  end

  defp handle_gap(state, %{"reason" => reason, "from_seq" => from, "to_seq" => to}) do
    state
    |> record_gap(reason, from, to)
    |> notify({:serial, {:gap, reason, from, to}})
  end

  defp handle_state(state, %{"state" => "connected", "detail" => detail}) do
    notify(%{state | status: :capturing}, {:serial, {:state, :connected, detail}})
  end

  defp handle_state(state, %{"state" => "disconnected", "detail" => detail}) do
    # A close we asked for ends as `closed`; a close we did not ask for is a
    # device that went away, and the two must not be recorded as the same fact.
    status = if state.status == :closing, do: :closed, else: :disconnected

    state = state |> commit_buffer() |> Map.put(:status, status)
    notify(state, {:serial, {:state, status, detail}})
  end

  defp handle_state(state, %{"state" => "error", "detail" => detail}) do
    state = state |> commit_buffer() |> Map.put(:status, :error)
    notify(state, {:serial, {:state, :error, detail}})
  end

  defp handle_protocol_error(state, reason) do
    Logger.error("serial helper protocol error on #{state.port_name}: #{inspect(reason)}")

    state
    |> record_gap("helper protocol error", nil, nil)
    |> Map.put(:status, :error)
    |> notify({:serial, {:state, :error, "protocol error: #{inspect(reason)}"}})
  end

  # A missing source_seq is the one thing the raw stream cannot express, because
  # the helper increments it per frame. Its absence means frames were lost.
  defp note_gap_before(%{last_source_seq: nil} = state, _seq), do: state

  defp note_gap_before(%{last_source_seq: previous} = state, seq) when seq <= previous + 1, do: state

  defp note_gap_before(%{last_source_seq: previous} = state, seq) do
    state
    |> record_gap("source_seq skip", previous + 1, seq - 1)
    |> notify({:serial, {:gap, "source_seq skip", previous + 1, seq - 1}})
  end

  defp record_gap(state, reason, from, to) do
    gap = %{reason: reason, from_seq: from, to_seq: to, observed_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    %{state | gaps: state.gaps ++ [gap]}
  end

  # ------------------------------------------------------------------
  # Chunking
  # ------------------------------------------------------------------

  defp append(state, bytes, seq) do
    buffer = [bytes | state.buffer]
    first_seq = state.buffer_first_seq || seq

    %{
      state
      | buffer: buffer,
        buffer_bytes: state.buffer_bytes + byte_size(bytes),
        buffer_first_seq: first_seq,
        buffer_started_at: state.buffer_started_at || now_ms()
    }
    |> add_recent(bytes, seq)
  end

  defp add_recent(state, bytes, seq) do
    row = %{
      "source_seq" => seq,
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "display_text" => display_text(bytes),
      "invalid_utf8" => not String.valid?(bytes),
      "raw_bytes" => byte_size(bytes)
    }

    recent = Enum.take([row | state.recent], @recent_limit)
    state = %{state | recent: recent}

    # A burst produces many frames; the page only needs to know that something
    # changed, so data notifications are coalesced.
    now = now_ms()

    if is_nil(state.last_notice_ms) or now - state.last_notice_ms >= @notice_interval_ms do
      notify(%{state | last_notice_ms: now, pending_notice_seq: nil}, {:serial, {:data, seq}})
    else
      %{state | pending_notice_seq: seq}
    end
  end

  # Coalescing can swallow the *last* frame of a burst, which would leave the
  # page stale until something else happened. The tick is the trailing edge: it
  # delivers the withheld notification. No interval check is needed here — the
  # tick period is already an order of magnitude longer than the window.
  defp flush_notice(%{pending_notice_seq: nil} = state), do: state

  defp flush_notice(%{pending_notice_seq: seq} = state) do
    notify(%{state | pending_notice_seq: nil, last_notice_ms: now_ms()}, {:serial, {:data, seq}})
  end

  # The display text is a *view*: it is derived from the raw bytes so invalid
  # UTF-8 still has something to show, and it is never the stored evidence.
  defp display_text(bytes) do
    if String.valid?(bytes), do: bytes, else: :unicode.characters_to_binary(bytes, :latin1)
  end

  defp maybe_commit_chunk(state) do
    if state.buffer_bytes >= @chunk_max_bytes or chunk_expired?(state) do
      commit_buffer(state)
    else
      state
    end
  end

  # Split by age as well as size, so a slow trickle still lands in the record
  # instead of sitting in memory until the session ends.
  defp chunk_max_age_ms(state), do: Keyword.get(state.config, :chunk_max_age_ms, @chunk_max_age_ms)

  defp chunk_expired?(state) do
    state.buffer_started_at != nil and now_ms() - state.buffer_started_at >= chunk_max_age_ms(state)
  end

  @doc """
  Close the current chunk: hash it, record its range, and store the bytes.

  A chunk with no bytes is not a chunk, so an idle session produces no empty
  entries in the evidence index.
  """
  @spec commit_buffer(State.t()) :: State.t()
  def commit_buffer(%State{buffer_bytes: 0} = state), do: reset_buffer(state)

  def commit_buffer(state) do
    bytes = state.buffer |> Enum.reverse() |> IO.iodata_to_binary()

    case put_blob(state, bytes) do
      {:ok, receipt} ->
        chunk = %{
          "chunk_index" => length(state.chunks),
          "blob_sha256" => receipt["sha256"],
          "size_bytes" => receipt["size_bytes"],
          "source_seq_start" => state.buffer_first_seq,
          "source_seq_end" => state.last_source_seq,
          "closed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        notify(reset_buffer(%{state | chunks: state.chunks ++ [chunk]}), {:serial, {:chunk, chunk}})

      {:error, code, details} ->
        Logger.error("could not commit serial chunk for #{state.port_name}: #{code} #{inspect(details)}")

        # Refusing to drop the bytes silently is the point: a failed commit is
        # reported as a gap so the record says the capture is incomplete.
        first = state.buffer_first_seq
        last = state.last_source_seq

        state
        |> record_gap("chunk commit failed: #{code}", first, last)
        |> reset_buffer()
        |> notify({:serial, {:gap, "chunk commit failed", first, last}})
    end
  end

  # A store outage is a capture problem, not a reason for the capture to die.
  defp put_blob(state, bytes) do
    Store.put_blob(state.project_id, bytes, "application/octet-stream", server: state.store)
  catch
    :exit, _reason -> {:error, :store_unavailable, %{project_id: state.project_id}}
  end

  defp reset_buffer(state) do
    %{state | buffer: [], buffer_bytes: 0, buffer_first_seq: nil, buffer_started_at: nil}
  end

  defp notify(%{owner: owner} = state, message) do
    send(owner, message)
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
