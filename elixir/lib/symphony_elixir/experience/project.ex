defmodule SymphonyElixir.Experience.Project do
  @moduledoc """
  The single workbench scope this instance serves, resolved once per call from
  the live workflow settings.

  First release runs one project per Symphony instance. Resolving the scope in
  one place keeps the Store, the provider adapter and the LiveViews from each
  inventing their own notion of "which project am I looking at".
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @enforce_keys [:project_id, :mode, :adapter, :store]
  defstruct [
    :project_id,
    :mode,
    :adapter,
    :store,
    :display_states,
    :data_root,
    :workspace_root,
    :domain_profile,
    :device_config,
    :archify_root,
    :tracker_settings
  ]

  @type t :: %__MODULE__{
          project_id: String.t(),
          mode: String.t(),
          adapter: module(),
          store: GenServer.server(),
          display_states: [String.t()],
          data_root: String.t() | nil,
          workspace_root: String.t() | nil,
          domain_profile: String.t() | nil,
          device_config: String.t() | nil,
          archify_root: String.t() | nil,
          tracker_settings: map() | nil
        }

  @doc """
  Resolve the workbench scope from the current workflow settings.

  Returns `{:error, :workbench_disabled, ...}` when the workflow has no enabled
  workbench, which callers must treat as "no workbench route", not as a fault.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, atom(), map()}
  def load(opts \\ []) do
    with {:ok, settings} <- Config.settings(),
         :ok <- enabled(settings.workbench) do
      {:ok, build(settings, opts)}
    else
      {:error, :workbench_disabled, %{} = details} ->
        {:error, :workbench_disabled, details}

      {:error, reason} ->
        {:error, :workbench_unavailable, %{reason: reason}}
    end
  end

  @doc """
  True when the workbench is both enabled in config and actually running.

  Configuration alone is not enough: the Experience subtree is only started when
  the HTTP server is up, so a UI must not claim a workbench it cannot reach.
  """
  @spec available?() :: boolean()
  def available? do
    match?({:ok, _project}, load())
  end

  defp enabled(%Schema.Workbench{enabled: true}), do: :ok

  defp enabled(%Schema.Workbench{} = workbench) do
    {:error, :workbench_disabled, %{reason: :disabled, mode: workbench.mode}}
  end

  defp build(%Schema{} = settings, opts) do
    %Schema.Workbench{} = workbench = settings.workbench

    %__MODULE__{
      project_id: workbench.project_id,
      mode: workbench.mode,
      adapter: adapter_for(workbench.mode),
      store: Keyword.get(opts, :store, SymphonyElixir.Experience.Store),
      display_states: workbench.display_states,
      data_root: workbench.data_root,
      workspace_root: settings.workspace.root,
      domain_profile: workbench.domain_profile,
      device_config: workbench.device_config,
      archify_root: workbench.archify_root,
      tracker_settings: settings.tracker
    }
  end

  defp adapter_for("demo"), do: SymphonyElixir.Experience.DemoAdapter
  defp adapter_for(_live), do: SymphonyElixir.Linear.WorkbenchAdapter
end
