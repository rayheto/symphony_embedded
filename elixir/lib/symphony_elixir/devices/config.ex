defmodule SymphonyElixir.Devices.Config do
  @moduledoc """
  The host's device inventory.

  Devices, image sources, decoders and actions come from a host-owned file, not
  from the browser and not from an agent: a caller can only name a key that is
  already registered here, and an action can only name an executable path and a
  fixed argument list that the host wrote.
  """

  require Logger

  @schema_version "1.0"

  defmodule Device do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [
      :key,
      :display_name,
      :adapter,
      :port,
      :hardware_revision,
      :build_id,
      :host_id,
      serial: %{},
      actions: [],
      supported_capabilities: []
    ]
  end

  defmodule Action do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [
      :tool_id,
      :executable,
      :timeout_ms,
      :required_capability,
      idempotent: false,
      preconditions: [],
      argv: []
    ]
  end

  defmodule ImageSource do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [:key, :label, :adapter, :available]
  end

  defmodule Decoder do
    @moduledoc false
    @type t :: %__MODULE__{}

    defstruct [:key, :display_name, :executable, :chip, :argv, :available]
  end

  defmodule Settings do
    @moduledoc false

    @type t :: %__MODULE__{}

    defstruct [
      :host_id,
      :serial,
      :storage,
      devices: [],
      actions: [],
      image_sources: [],
      decoders: [],
      session_supervisor: nil,
      limitations: []
    ]
  end

  @spec empty() :: Settings.t()
  def empty do
    %Settings{
      host_id: "unknown-host",
      serial: %{},
      storage: %{},
      limitations: ["宿主没有配置设备清单，设备相关能力均不可用。"]
    }
  end

  @doc """
  Load the device inventory from the configured path.

  A missing or unreadable file is not an error: the workbench must still run,
  with device capabilities reported as unavailable and the reason stated.
  """
  @spec load(String.t() | nil) :: {:ok, Settings.t()} | {:error, atom(), map()}
  def load(nil), do: {:ok, empty()}

  def load(path) when is_binary(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, %{empty() | limitations: ["设备配置文件不存在：#{path}"]}}
      {:error, reason} -> {:error, :device_config_unreadable, %{path: path, reason: reason}}
      {:ok, contents} -> decode(path, contents)
    end
  end

  defp decode(path, contents) do
    with {:ok, raw} <- YamlElixir.read_from_string(contents),
         %{} = raw <- raw,
         :ok <- check_version(raw) do
      {:ok, build(raw)}
    else
      {:error, code, details} ->
        {:error, code, details}

      {:error, reason} ->
        {:error, :device_config_invalid, %{path: path, reason: inspect(reason)}}

      _other ->
        {:error, :device_config_invalid, %{path: path, reason: "not a mapping"}}
    end
  end

  defp check_version(%{"schema_version" => version}) when version == @schema_version, do: :ok

  defp check_version(%{"schema_version" => version}) do
    {:error, :unsupported_device_config_version, %{schema_version: version, supported: @schema_version}}
  end

  defp check_version(_raw), do: {:error, :device_config_invalid, %{reason: "schema_version is required"}}

  defp build(raw) do
    actions = Enum.map(Map.get(raw, "actions", []), &build_action/1)
    devices = Enum.map(Map.get(raw, "devices", []), &build_device(&1, actions))

    %Settings{
      host_id: Map.get(raw, "host_id", "unknown-host"),
      serial: Map.get(raw, "serial", %{}),
      storage: Map.get(raw, "storage", %{}),
      devices: devices,
      actions: actions,
      image_sources: Enum.map(Map.get(raw, "image_sources", []), &build_image_source/1),
      decoders: Enum.map(Map.get(raw, "decoders", []), &build_decoder/1),
      limitations: []
    }
  end

  defp build_device(raw, actions) do
    key = Map.get(raw, "key")

    %Device{
      key: key,
      display_name: Map.get(raw, "display_name", key),
      adapter: Map.get(raw, "adapter", "serial"),
      port: Map.get(raw, "port"),
      hardware_revision: Map.get(raw, "hardware_revision"),
      build_id: Map.get(raw, "build_id"),
      host_id: Map.get(raw, "host_id"),
      serial: Map.get(raw, "serial", %{}),
      supported_capabilities: Map.get(raw, "supported_capabilities", []),
      actions: Enum.filter(actions, &(&1.tool_id in Map.get(raw, "action_ids", [])))
    }
  end

  # The executable must be an absolute path written by the host: a relative
  # name would be resolved against the service account's PATH at run time.
  defp build_action(raw) do
    executable = Map.get(raw, "absolute_executable")

    %Action{
      tool_id: Map.get(raw, "tool_id"),
      executable: executable,
      argv: Enum.map(Map.get(raw, "fixed_argv_template", []), &to_string/1),
      timeout_ms: Map.get(raw, "timeout_ms", 30_000),
      required_capability: Map.get(raw, "required_capability", "control"),
      idempotent: Map.get(raw, "idempotent", false),
      preconditions: Map.get(raw, "preconditions", [])
    }
  end

  defp build_image_source(raw) do
    %ImageSource{
      key: Map.get(raw, "key"),
      label: Map.get(raw, "label", Map.get(raw, "key")),
      adapter: Map.get(raw, "adapter"),
      available: Map.get(raw, "available", true)
    }
  end

  defp build_decoder(raw) do
    %Decoder{
      key: Map.get(raw, "key"),
      display_name: Map.get(raw, "display_name"),
      executable: Map.get(raw, "absolute_executable"),
      chip: Map.get(raw, "chip"),
      argv: Enum.map(Map.get(raw, "fixed_argv_template", []), &to_string/1),
      available: Map.get(raw, "available", true)
    }
  end
end
