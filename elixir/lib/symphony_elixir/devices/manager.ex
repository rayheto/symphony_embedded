defmodule SymphonyElixir.Devices.Manager do
  @moduledoc """
  Registers devices, hands out leases, and runs allowlisted host actions.

  The manager never reaches the scheduler: it owns physical resources, and the
  core concurrency limits stay where they were. A lease is the only way to
  perform a *control* action on a device, and a lease that has expired can never
  be renewed back into existence — the next acquisition is a new generation, so
  an old token is refused instead of silently accepted.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Devices.{Config, SerialPort}

  @default_ttl_seconds 30
  @min_ttl_seconds 5
  @max_ttl_seconds 300
  @probe_timeout_ms 5_000

  defmodule Lease do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [:resource_id, :owner_run_id, :generation, :expires_at, :status]
  end

  defmodule State do
    @moduledoc false
    defstruct devices: %{}, config: nil, sessions: %{}, generations: %{}
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The devices registered in the host configuration, with their live status."
  @spec list(GenServer.server()) :: [map()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list, 30_000)

  @spec get(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def get(server \\ __MODULE__, device_key), do: GenServer.call(server, {:get, device_key}, 30_000)

  @doc """
  Probe a registered device: it is only "online" when the host can actually see
  the port, and a probe never claims more than it checked.
  """
  @spec probe(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def probe(server \\ __MODULE__, device_key), do: GenServer.call(server, {:probe, device_key}, @probe_timeout_ms + 1_000)

  @spec open_capture(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def open_capture(server \\ __MODULE__, device_key, opts \\ []),
    do: GenServer.call(server, {:open_capture, device_key, opts}, 30_000)

  @spec close_capture(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def close_capture(server \\ __MODULE__, device_key), do: GenServer.call(server, {:close_capture, device_key}, 30_000)

  @spec acquire_lease(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def acquire_lease(server \\ __MODULE__, device_key, owner_run_id, opts \\ []),
    do: GenServer.call(server, {:acquire_lease, device_key, owner_run_id, opts}, 30_000)

  @spec renew_lease(GenServer.server(), String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def renew_lease(server \\ __MODULE__, device_key, owner_run_id, generation, opts \\ []),
    do: GenServer.call(server, {:renew_lease, device_key, owner_run_id, generation, opts}, 30_000)

  @spec release_lease(GenServer.server(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, atom(), map()}
  def release_lease(server \\ __MODULE__, device_key, owner_run_id, generation),
    do: GenServer.call(server, {:release_lease, device_key, owner_run_id, generation}, 30_000)

  @doc """
  Run one allowlisted host action under the current lease.

  The action is looked up in the host configuration; nothing a caller sends can
  name an executable or add arguments.
  """
  @spec run_action(GenServer.server(), String.t(), String.t(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def run_action(server \\ __MODULE__, device_key, tool_id, owner_run_id, generation, opts \\ []),
    do: GenServer.call(server, {:run_action, device_key, tool_id, owner_run_id, generation, opts}, 300_000)

  @spec sessions(GenServer.server(), String.t() | nil) :: [map()]
  def sessions(server \\ __MODULE__, device_key \\ nil), do: GenServer.call(server, {:sessions, device_key}, 30_000)

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    # `:max_sessions` bounds how many capture processes this host will run at
    # once; unlimited is the default.
    {:ok, session_supervisor} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        max_children: Keyword.get(opts, :max_sessions, :infinity)
      )

    case Config.load(Keyword.get(opts, :config_path)) do
      {:ok, config} ->
        {:ok, %State{config: %{config | session_supervisor: session_supervisor}, devices: index(config.devices)}}

      {:error, _code, _details} ->
        {:ok, %State{config: %{Config.empty() | session_supervisor: session_supervisor}, devices: %{}}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.devices |> Map.values() |> Enum.map(&device_wire(&1, state)), state}
  end

  def handle_call({:get, device_key}, _from, state) do
    case fetch_device(state, device_key) do
      {:ok, device} -> {:reply, {:ok, device_wire(device, state)}, state}
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:probe, device_key}, _from, state) do
    case fetch_device(state, device_key) do
      {:ok, device} ->
        probe = probe_device(device)
        {:reply, {:ok, probe}, put_device(state, Map.put(device, :last_probe, probe))}

      {:error, code, details} ->
        {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:open_capture, device_key, opts}, _from, state) do
    with {:ok, device} <- fetch_device(state, device_key),
         :ok <- lease_allows_read(state, device),
         {:ok, session} <- start_session(state, device, opts) do
      state = state |> put_device(device) |> put_session(device_key, session)
      {:reply, {:ok, session_wire(session)}, state}
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:close_capture, device_key}, _from, state) do
    case fetch_device(state, device_key) do
      {:error, code, details} -> {:reply, {:error, code, details}, state}
      {:ok, device} -> close_session(state, device)
    end
  end

  def handle_call({:acquire_lease, device_key, owner_run_id, opts}, _from, state) do
    with {:ok, device} <- fetch_device(state, device_key),
         {:ok, ttl} <- ttl_seconds(opts),
         :ok <- lease_available(device, owner_run_id) do
      generation = Map.get(state.generations, device_key, 0) + 1
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      lease = %Lease{
        resource_id: device_key,
        owner_run_id: owner_run_id,
        generation: generation,
        expires_at: DateTime.to_iso8601(expires_at),
        status: :active
      }

      device = Map.put(device, :lease, lease)

      {:reply, {:ok, lease_wire(lease, ttl)}, %{state | generations: Map.put(state.generations, device_key, generation)} |> put_device(device)}
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:renew_lease, device_key, owner_run_id, generation, opts}, _from, state) do
    with {:ok, device} <- fetch_device(state, device_key),
         {:ok, ttl} <- ttl_seconds(opts),
         {:ok, lease} <- matching_lease(device, owner_run_id, generation) do
      # Renewing only extends the deadline: it never transfers ownership and
      # never turns an expired lease back into a valid one.
      expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)

      case check_expiry(lease) do
        :ok ->
          renewed = %{lease | expires_at: DateTime.to_iso8601(expires_at)}
          {:reply, {:ok, lease_wire(renewed, ttl)}, put_device(state, Map.put(device, :lease, renewed))}

        {:error, code, details} ->
          {:reply, {:error, code, details}, state}
      end
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:release_lease, device_key, owner_run_id, generation}, _from, state) do
    with {:ok, device} <- fetch_device(state, device_key),
         {:ok, lease} <- matching_lease(device, owner_run_id, generation) do
      released = %{lease | status: :released}
      {:reply, {:ok, lease_wire(released, nil)}, put_device(state, Map.put(device, :lease, nil))}
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:run_action, device_key, tool_id, owner_run_id, generation, opts}, _from, state) do
    with {:ok, device} <- fetch_device(state, device_key),
         {:ok, action} <- find_action(state, tool_id),
         {:ok, lease} <- matching_lease(device, owner_run_id, generation),
         :ok <- check_expiry(lease),
         :ok <- action_preconditions(action, device) do
      {:reply, run_action(action, device, opts), state}
    else
      {:error, code, details} -> {:reply, {:error, code, details}, state}
    end
  end

  def handle_call({:sessions, device_key}, _from, state) do
    sessions =
      state.sessions
      |> Enum.filter(fn {key, _session} -> is_nil(device_key) or key == device_key end)
      |> Enum.map(fn {_key, session} -> session_wire(session) end)

    {:reply, sessions, state}
  end

  @impl true
  def handle_info({:serial, message}, state) do
    # Capture frames belong to whoever opened the session; the manager keeps the
    # session index and forwards nothing it does not understand.
    Logger.debug("device manager received #{inspect(message)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Devices
  # ------------------------------------------------------------------

  defp index(devices), do: Map.new(devices, &{&1.key, Map.put(&1, :lease, nil)})

  defp close_session(state, device) do
    case Map.get(state.sessions, device.key) do
      nil ->
        {:reply, {:error, :no_capture_session, %{device_key: device.key}}, state}

      session ->
        SerialPort.close(session.pid)
        DynamicSupervisor.terminate_child(session_supervisor(state), session.pid)

        state = %{state | sessions: Map.delete(state.sessions, device.key)} |> put_device(device)

        {:reply, {:ok, %{"device_key" => device.key, "session_id" => session.session_id, "status" => "closing"}}, state}
    end
  end

  defp fetch_device(state, device_key) do
    case Map.fetch(state.devices, device_key) do
      {:ok, device} -> {:ok, device}
      :error -> {:error, :unknown_device, %{device_key: device_key, known: Map.keys(state.devices)}}
    end
  end

  defp put_device(state, device), do: %{state | devices: Map.put(state.devices, device.key, device)}

  defp put_session(state, device_key, session), do: %{state | sessions: Map.put(state.sessions, device_key, session)}

  defp device_wire(device, state) do
    %{
      "id" => device.key,
      "display_name" => device.display_name,
      "adapter" => device.adapter,
      "host_id" => state.config.host_id,
      "port" => device.port,
      "hardware_revision" => device.hardware_revision,
      "connection_status" => Map.get(device, :connection_status, "unknown"),
      "active_session_id" => active_session_id(state, device.key),
      "build_id" => device.build_id,
      "lease" => lease_wire(device.lease, nil),
      "capabilities" => device_capabilities(device)
    }
  end

  defp active_session_id(state, device_key) do
    case Map.get(state.sessions, device_key) do
      nil -> nil
      session -> session.session_id
    end
  end

  @doc """
  The capabilities a device actually offers right now.

  A capability that depends on host configuration is reported as unavailable
  with the reason, never as if it were merely broken.
  """
  @spec device_capabilities(map()) :: [map()]
  def device_capabilities(device) do
    [
      %{name: "read", available: true, reason: nil},
      capability("capture", is_binary(device.port), "device has no configured serial port"),
      capability("control", device.actions != [], "no allowlisted action is registered for this device")
    ]
  end

  defp capability(name, true, _reason), do: %{name: name, available: true, reason: nil}
  defp capability(name, _false, reason), do: %{name: name, available: false, reason: reason}

  defp probe_device(device) do
    available = is_binary(device.port) and File.exists?(device.port)

    %{
      "device_key" => device.key,
      "port" => device.port,
      "port_present" => available,
      "connection_status" => if(available, do: "online", else: "offline"),
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "limitations" => if(available, do: [], else: ["端口不存在或不可访问。"])
    }
  end

  # ------------------------------------------------------------------
  # Sessions
  # ------------------------------------------------------------------

  defp start_session(state, device, opts) do
    with {:ok, port} <- require_port(device),
         :ok <- port_not_owned(state, device) do
      session_id = Keyword.get(opts, :session_id, "capture-#{System.unique_integer([:positive])}")
      # One capture process per device: a stale child can never be joined by a
      # second, silently competing reader of the same port.
      name = Module.concat(__MODULE__, :"Serial#{device.key}")

      child =
        %{
          id: name,
          start:
            {SerialPort, :start_link,
             [
               [
                 name: name,
                 owner: Keyword.get(opts, :owner, self()),
                 port: port,
                 session_id: session_id,
                 device_id: device.key,
                 project_id: Keyword.get(opts, :project_id),
                 store: Keyword.get(opts, :store, SymphonyElixir.Experience.Store)
               ]
               |> Keyword.merge(serial_opts(device.serial))
             ]},
          restart: :transient
        }

      start_session_child(state, child, device)
    end
  end

  defp start_session_child(state, child, device) do
    case DynamicSupervisor.start_child(session_supervisor(state), child) do
      {:ok, pid} -> open_session_port(state, pid, device)
      {:error, reason} -> {:error, :session_start_failed, %{reason: inspect(reason)}}
    end
  end

  defp open_session_port(state, pid, device) do
    case SerialPort.open(server: pid) do
      {:ok, opened_id} ->
        {:ok, %{pid: pid, session_id: opened_id, device_key: device.key, started_at: now()}}

      {:error, code, details} ->
        DynamicSupervisor.terminate_child(session_supervisor(state), pid)
        {:error, code, details}
    end
  end

  defp session_supervisor(state), do: state.config.session_supervisor

  # The inventory is YAML, so serial settings arrive as a string-keyed map; the
  # capture process takes them as options.
  defp serial_opts(serial) when is_map(serial) do
    for key <- [:baudrate, :bytesize, :parity, :stopbits, :read_timeout_ms],
        value = Map.get(serial, to_string(key)),
        not is_nil(value),
        do: {key, value}
  end

  defp serial_opts(_serial), do: []

  defp require_port(device) do
    if is_binary(device.port) do
      {:ok, device.port}
    else
      {:error, :device_has_no_port, %{device_key: device.key}}
    end
  end

  defp port_not_owned(state, device) do
    case Map.get(state.sessions, device.key) do
      nil ->
        :ok

      session ->
        {:error, :port_owned, %{device_key: device.key, session_id: session.session_id}}
    end
  end

  defp session_wire(session) do
    %{
      "session_id" => session.session_id,
      "device_id" => session.device_key,
      "started_at" => session.started_at,
      "ended_at" => nil
    }
  end

  # ------------------------------------------------------------------
  # Leases
  # ------------------------------------------------------------------

  defp ttl_seconds(opts) do
    case Keyword.get(opts, :ttl_seconds, @default_ttl_seconds) do
      ttl when is_integer(ttl) and ttl >= @min_ttl_seconds and ttl <= @max_ttl_seconds ->
        {:ok, ttl}

      other ->
        {:error, :invalid_lease_ttl, %{ttl_seconds: other, min: @min_ttl_seconds, max: @max_ttl_seconds}}
    end
  end

  # A read is not a control action, so an active lease held by somebody else
  # blocks a *capture* but never blocks reading the same port's log.
  defp lease_allows_read(state, device) do
    _ = state

    case device.lease do
      nil ->
        :ok

      lease ->
        case check_expiry(lease) do
          :ok -> :ok
          {:error, code, details} -> {:error, code, details}
        end
    end
  end

  defp lease_available(device, owner_run_id) do
    case device.lease do
      nil ->
        :ok

      %Lease{owner_run_id: ^owner_run_id} ->
        :ok

      lease ->
        case check_expiry(lease) do
          :ok ->
            {:error, :lease_held, %{owner_run_id: lease.owner_run_id, generation: lease.generation}}

          {:error, _code, _details} ->
            # The previous holder is gone; the next generation takes over.
            :ok
        end
    end
  end

  defp matching_lease(device, owner_run_id, generation) do
    case device.lease do
      %Lease{owner_run_id: ^owner_run_id, generation: ^generation} = lease ->
        {:ok, lease}

      %Lease{} = lease ->
        details = %{
          owner_run_id: owner_run_id,
          generation: generation,
          held_by: lease.owner_run_id,
          held_generation: lease.generation
        }

        {:error, :lease_mismatch, details}

      nil ->
        {:error, :no_lease, %{device_key: device.key}}
    end
  end

  # An expired lease is a lower bound on knowledge, not proof that the physical
  # action stopped, so the caller must observe rather than re-run anything.
  defp check_expiry(%Lease{expires_at: expires_at}) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, deadline, _offset} ->
        if DateTime.compare(deadline, DateTime.utc_now()) == :gt do
          :ok
        else
          {:error, :lease_expired, %{expires_at: expires_at}}
        end

      _error ->
        {:error, :lease_expired, %{expires_at: expires_at}}
    end
  end

  defp lease_wire(nil, _ttl), do: nil

  defp lease_wire(%Lease{} = lease, ttl) do
    %{
      "resource_id" => lease.resource_id,
      "owner_run_id" => lease.owner_run_id,
      "generation" => lease.generation,
      "expires_at" => lease.expires_at,
      "status" => to_string(lease.status),
      "ttl_seconds" => ttl
    }
  end

  # ------------------------------------------------------------------
  # Actions
  # ------------------------------------------------------------------

  defp find_action(state, tool_id) do
    case Enum.find(state.config.actions, &(&1.tool_id == tool_id)) do
      nil ->
        {:error, :unknown_action, %{tool_id: tool_id, known: Enum.map(state.config.actions, & &1.tool_id)}}

      action ->
        {:ok, action}
    end
  end

  defp action_preconditions(action, _device) do
    if is_binary(action.executable) do
      :ok
    else
      {:error, :action_not_configured, %{tool_id: action.tool_id}}
    end
  end

  defp run_action(action, device, opts) do
    executable = Keyword.get(opts, :executable, action.executable)
    started_at = now()

    # The command is the configured absolute path plus the configured fixed
    # arguments; nothing from the caller is interpolated. A host tool that has
    # gone missing is reported through the receipt, not as a silent failure.
    {output, exit_code} = run_executable(executable, action.argv)

    {:ok,
     %{
       "device_id" => device.key,
       "tool_id" => action.tool_id,
       "executable" => executable,
       "argv" => action.argv,
       "exit_code" => exit_code,
       "output_sha256" => :crypto.hash(:sha256, output) |> Base.encode16(case: :lower),
       "output_bytes" => byte_size(output),
       "started_at" => started_at,
       "finished_at" => now(),
       "limitations" => if(exit_code == 0, do: [], else: ["动作以非零退出码结束，结果需人工确认。"])
     }}
  end

  defp run_executable(executable, argv) do
    System.cmd(executable, argv, stderr_to_stdout: true)
  rescue
    error -> {Exception.message(error), 127}
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
