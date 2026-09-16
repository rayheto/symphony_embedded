defmodule SymphonyElixir.Experience.Supervisor do
  @moduledoc """
  Owns the workbench's own processes.

  The workbench runs in its own subtree so a workbench fault can never take the
  scheduler down, and so a workflow with no workbench section costs nothing: the
  subtree starts with no children at all.
  """

  use Supervisor

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Experience.{DemoAdapter, Store}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @doc """
  The child list the workbench would start right now, or `[]` when it is off.

  Exposed so the running configuration can be inspected without guessing from
  process presence.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    case Config.settings() do
      {:ok, %Schema{workbench: %Schema.Workbench{enabled: true, data_root: data_root} = workbench} = settings} ->
        build_children(workbench, data_root, settings.workspace.root)

      _disabled ->
        []
    end
  end

  defp build_children(workbench, data_root, workspace_root) do
    case Store.validate_data_root(data_root, workspace_root) do
      :ok ->
        [{Store, name: Store, data_root: data_root, workspace_root: workspace_root}] ++ demo_children(workbench)

      {:error, code, details} ->
        # A bad data root disables durable engineering records; it must not take
        # the scheduler or the rest of the application down with it.
        Logger.error("Workbench store disabled: #{code} #{inspect(details)}")
        demo_children(workbench)
    end
  end

  # Only the isolated demonstration provider runs inside the workbench subtree;
  # the live provider is reached through the host tracker client.
  defp demo_children(%Schema.Workbench{mode: "demo"}), do: [{DemoAdapter, []}]
  defp demo_children(_workbench), do: []
end
