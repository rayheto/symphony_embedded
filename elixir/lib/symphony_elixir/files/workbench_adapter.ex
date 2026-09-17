defmodule SymphonyElixir.Files.WorkbenchAdapter do
  @moduledoc """
  Workbench provider for projects whose records live in their own repository.

  A project can keep its engineering truth as files — a `task.md` / `handoff.md`
  per task, plus whatever a task bridge writes beside it. Such a project has no
  hosted tracker and must not need one, so this adapter reads those files as the
  issue truth and refuses every write: the workbench never edits an adopting
  project's repository.

  Two consequences worth stating plainly, because they are what the workbench
  will show:

    * a run's state is the *record's own* word (`complete`, `partial`,
      `blocked`, or a bridged transport lifecycle) and a verdict the record never
      declared is `delivered`, i.e. it wants a human — this adapter never
      upgrades a self-report into an acceptance;
    * issues are never dispatchable here. Scheduling stays with the configured
      tracker; the board is a read-only projection of the project's records.
  """

  @behaviour SymphonyElixir.Experience.WorkbenchAdapter

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Experience.DisplayMapping
  alias SymphonyElixir.Experience.WorkbenchAdapter
  alias SymphonyElixir.Files.RunRecords
  alias SymphonyElixir.Tracker.Issue

  # States that mean work is still moving, versus states that mean it stopped
  # and therefore needs a person. Everything the reader reports is listed here;
  # a project's own extra verdict word is neither, so it lands in the review
  # column rather than being guessed into "in progress".
  # Every write is refused with this reason, so a UI that offers an action this
  # provider cannot honour gets an explicit answer instead of a silent success.
  @write_reason "记录是工程自己的文件：工作台只读它们，不往工程仓库里写"

  @active_states ["open", "claimed"]
  @terminal_states ["complete"]

  @impl true
  def capabilities do
    [
      WorkbenchAdapter.capability("read", true, nil),
      WorkbenchAdapter.capability("create_issue", false, @write_reason),
      WorkbenchAdapter.capability("comment", false, @write_reason),
      WorkbenchAdapter.capability("change_state", false, @write_reason),
      WorkbenchAdapter.capability("pause", false, @write_reason),
      WorkbenchAdapter.capability("resume", false, @write_reason),
      WorkbenchAdapter.capability("workpad", false, "记录文件里没有 workpad"),
      WorkbenchAdapter.capability("native_url", false, "记录是仓库里的文件，没有原生 issue URL")
    ]
  end

  @doc "Why this provider refuses every write."
  @spec write_reason() :: String.t()
  def write_reason, do: @write_reason

  @impl true
  def metadata(opts \\ []) do
    display_states = Keyword.get(opts, :display_states, [])

    with {:ok, records} <- read(opts) do
      {:ok,
       %{
         provider: "files",
         provider_project_id: Keyword.get(opts, :project_id) || "unknown",
         states: state_options(records, display_states),
         assignees: assignees(records),
         labels: labels(records),
         capabilities: capabilities(),
         fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         stale: false
       }}
    end
  end

  @impl true
  def list_issues(opts \\ []) do
    with {:ok, records} <- read(opts) do
      {:ok, Enum.map(records, &to_issue/1)}
    end
  end

  @impl true
  def get_issue(issue_id, opts \\ []) do
    with {:ok, records} <- read(opts) do
      case Enum.find(records, &(&1.id == issue_id)) do
        nil -> {:error, :not_found, %{issue_id: issue_id}}
        record -> {:ok, to_issue(record)}
      end
    end
  end

  @impl true
  def create_issue(_attrs, opts \\ []), do: refuse("create_issue", opts)

  @impl true
  def transition(_issue_id, _target_state, opts \\ []), do: refuse("change_state", opts)

  @impl true
  def comment(_issue_id, _body, opts \\ []), do: refuse("comment", opts)

  @impl true
  def secret_environment_names, do: []

  @doc """
  The record root this provider reads for the given call.

  An explicit `:record_root` wins so tests and one-off calls can point anywhere;
  otherwise the running workflow's `workbench.record_root` is used.
  """
  @spec record_root(keyword()) :: String.t() | nil
  def record_root(opts \\ []) do
    case Keyword.get(opts, :record_root) do
      nil -> configured(& &1.record_root)
      root -> root
    end
  end

  @doc """
  The bridge task directory for the given call, when one is configured.

  Without it the run records stand alone; the bridge is an auxiliary record of
  transport lifecycle, not the project's record of its own work.
  """
  @spec bridge_tasks(keyword()) :: String.t() | nil
  def bridge_tasks(opts \\ []) do
    case Keyword.get(opts, :bridge_tasks) do
      nil -> configured(& &1.bridge_tasks)
      dir -> dir
    end
  end

  @doc """
  What a bridge task's payload must mention to belong to this project.

  A bridge directory is shared between projects, so without a marker every
  project's tasks would land on this board. No marker means no filtering.
  """
  @spec bridge_marker(keyword()) :: String.t() | nil
  def bridge_marker(opts \\ []) do
    case Keyword.get(opts, :bridge_marker) do
      nil -> configured(& &1.bridge_task_marker)
      marker -> marker
    end
  end

  # The host's own settings, read the same way the tracker client reads them: a
  # workflow that cannot be parsed at all is the host's fault and is reported
  # through `Project.load/0` before any provider call is reached.
  defp configured(field) do
    %Schema{workbench: %Schema.Workbench{} = workbench} = Config.settings!()
    field.(workbench)
  end

  defp read(opts) do
    case record_root(opts) do
      nil ->
        {:error, :record_root_missing, %{reason: "files mode needs workbench.record_root", mode: "files"}}

      root ->
        RunRecords.read(root,
          bridge_tasks: bridge_tasks(opts),
          bridge_marker: bridge_marker(opts)
        )
    end
  end

  defp refuse(capability, _opts) do
    {:error, :unsupported_capability, %{capability: capability, reason: @write_reason, mode: "files"}}
  end

  defp to_issue(record) do
    %Issue{
      id: record.id,
      native_ref: native_ref(record),
      identifier: record.id,
      title: record.title,
      description: record.description,
      state: record.state,
      url: nil,
      assignee_id: record.owner,
      labels: labels_of(record),
      blocked_by: [],
      dispatchable: false,
      created_at: oldest(record.mtimes),
      updated_at: newest(record.mtimes)
    }
  end

  defp native_ref(record) do
    %{
      "provider" => "files",
      "sources" => record.sources,
      "bridge" => bridge_ref(record.bridge)
    }
  end

  defp bridge_ref(nil), do: nil

  defp bridge_ref(bridge) do
    %{
      "status" => bridge.status,
      "task_id" => bridge[:task_id],
      "claimed_by" => bridge.claimed_by,
      "created_at" => iso(bridge[:created_at]),
      "updated_at" => iso(bridge[:updated_at])
    }
  end

  # The project's own naming carries the layer (`l2_cst9217_touch_e4c8` was an
  # L2 task), and a record that exists only in the bridge is marked as such:
  # both are derived from the records, never invented.
  defp labels_of(record) do
    [layer_label(record.id), if(record.bridge_only, do: "桥接", else: nil)]
    |> Enum.reject(&is_nil/1)
  end

  defp layer_label(id) do
    case Regex.run(~r/^l([0-4])[_-]/i, id, capture: :all_but_first) do
      [level] -> "L" <> level
      _other -> nil
    end
  end

  defp state_options(records, display_states) do
    records
    |> Enum.map(& &1.state)
    |> Enum.concat(RunRecords.states())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      active = name in @active_states
      terminal = name in @terminal_states

      %{
        id: name,
        name: name,
        display_column: DisplayMapping.column_for(name, active, terminal, display_states),
        active: active,
        terminal: terminal
      }
    end)
  end

  defp assignees(records) do
    records
    |> Enum.map(& &1.owner)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{id: &1, name: &1})
  end

  defp labels(records) do
    records
    |> Enum.flat_map(&labels_of/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{id: &1, name: &1})
  end

  defp oldest([]), do: nil
  defp oldest(times), do: Enum.min(times)

  defp newest([]), do: nil
  defp newest(times), do: Enum.max(times)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
