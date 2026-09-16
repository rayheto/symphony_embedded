defmodule SymphonyElixir.Experience.DemoAdapter do
  @moduledoc """
  Read-only demonstration provider.

  Demo mode exists so the workbench can be exercised without a tracker account.
  It never reaches a real provider or device; writes land in an isolated
  in-memory demonstration state, and every surface that shows this data must
  keep the fixture's demonstration notice visible.
  """

  @behaviour SymphonyElixir.Experience.WorkbenchAdapter

  alias SymphonyElixir.Experience.WorkbenchAdapter
  alias SymphonyElixir.Tracker.Issue

  @fixture "demo.json"
  @state_name __MODULE__.State

  # The demonstration fixture mirrors the real Linear profile described in
  # docs/STATE_AND_CONSISTENCY.md: only these states are dispatchable, and only
  # these are finished. "Human Review" is deliberately neither.
  @active_states ["Todo", "In Progress", "Rework", "Merging"]
  @terminal_states ["Done", "Closed", "Cancelled", "Canceled"]

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @state_name)
    Agent.start_link(fn -> initial_state() end, name: name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @impl true
  def capabilities do
    [
      WorkbenchAdapter.capability("read", true, nil),
      WorkbenchAdapter.capability("create_issue", true, nil),
      WorkbenchAdapter.capability("comment", true, nil),
      WorkbenchAdapter.capability("change_state", true, nil),
      WorkbenchAdapter.capability("pause", false, "demo mode has no real tracker to pause"),
      WorkbenchAdapter.capability("resume", false, "demo mode has no real tracker to resume"),
      WorkbenchAdapter.capability("workpad", false, "demo mode has no provider workpad"),
      WorkbenchAdapter.capability("native_url", false, "demo mode has no native issue URL")
    ]
  end

  @impl true
  def metadata(opts \\ []) do
    demo = demo(opts)

    {:ok,
     %{
       provider: "demo",
       provider_project_id: demo.project_id,
       states: demo.state_options,
       assignees: demo.assignees,
       labels: demo.labels,
       capabilities: capabilities(),
       fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       stale: false
     }}
  end

  @impl true
  def validate_metadata(_opts \\ []), do: :ok

  @impl true
  def list_issues(opts \\ []) do
    issues = opts |> state() |> Map.fetch!(:issues) |> Enum.map(&to_issue/1)

    {:ok, issues}
  end

  @impl true
  def get_issue(issue_id, opts \\ []) do
    issues = opts |> state() |> Map.fetch!(:issues)

    case Enum.find(issues, fn issue -> issue["id"] == issue_id or issue["identifier"] == issue_id end) do
      nil -> {:error, :not_found, %{issue_id: issue_id}}
      issue -> {:ok, to_issue(issue)}
    end
  end

  @impl true
  def create_issue(attrs, opts \\ []) do
    with :ok <- demo_running?(opts) do
      issue = new_demo_issue(if(is_map(attrs), do: attrs, else: %{}), opts)
      Agent.update(state_name(opts), &%{&1 | issues: [issue | &1.issues]})
      {:ok, %{id: issue["id"], identifier: issue["identifier"], native_state: issue["native_state"]}}
    end
  end

  @impl true
  def transition(issue_id, target_state, opts \\ []) do
    with :ok <- demo_running?(opts),
         {:ok, issue} <- update_issue(opts, issue_id, &Map.put(&1, "native_state", target_state)) do
      {:ok, %{id: issue["id"], native_state: issue["native_state"]}}
    end
  end

  @impl true
  def comment(issue_id, body, opts \\ []) do
    with :ok <- demo_running?(opts) do
      key = {:comment, issue_id, body}

      Agent.update(state_name(opts), fn demo_state ->
        %{demo_state | comments: Map.put_new(demo_state.comments, key, now())}
      end)

      {:ok, %{id: issue_id, recorded: true}}
    end
  end

  @impl true
  def find_operation_marker(_issue_id, _opts \\ []), do: {:ok, nil}

  @impl true
  def get_workpad(_issue_id, _opts \\ []), do: {:ok, nil}

  @impl true
  def update_workpad_plan(_issue_id, _plan, _opts \\ []) do
    {:error, :unsupported_capability, %{capability: "workpad", reason: "demo mode has no provider workpad"}}
  end

  @impl true
  def secret_environment_names, do: []

  @doc "The demonstration notice that must stay visible wherever demo data appears."
  @spec notice(keyword()) :: String.t()
  def notice(opts \\ []) do
    demo(opts).notice
  end

  @doc "Loaded fixture data for the current demonstration project."
  @spec demo(keyword()) :: map()
  def demo(opts \\ []) do
    state(opts).demo
  end

  @doc "Restore the fixture's original demonstration state."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Agent.update(state_name(opts), fn _state -> initial_state() end)
  end

  defp initial_state do
    demo = load_fixture()
    %{demo: demo, issues: demo.issues, comments: %{}}
  end

  defp load_fixture do
    path = Application.app_dir(:symphony_elixir, ["priv", "workbench", @fixture])

    %{
      "project_id" => project_id,
      "notice" => notice,
      "issues" => issues,
      "problems" => problems,
      "evidence" => evidence,
      "validations" => validations,
      "decisions" => decisions,
      "devices" => devices,
      "sessions" => sessions,
      "operations" => operations,
      "events" => events,
      "display" => display,
      "clock_utc" => clock
    } = Jason.decode!(File.read!(path))

    %{
      project_id: project_id,
      notice: notice,
      clock_utc: clock,
      issues: issues,
      problems: problems,
      evidence: evidence,
      validations: validations,
      decisions: decisions,
      devices: devices,
      sessions: sessions,
      operations: operations,
      events: events,
      display: display,
      display_states: display |> Map.get("column_counts", %{}) |> Map.keys(),
      state_options: state_options(issues, display),
      assignees: assignees(issues),
      labels: labels(issues)
    }
  end

  defp state_options(issues, _display) do
    native_states = issues |> Enum.map(& &1["native_state"]) |> Enum.uniq()

    Enum.map(native_states, fn state ->
      column = issues |> Enum.find(&(&1["native_state"] == state)) |> Map.fetch!("display_column")

      %{
        id: state,
        name: state,
        display_column: column,
        active: state in @active_states,
        terminal: state in @terminal_states
      }
    end)
  end

  defp assignees(issues) do
    issues
    |> Enum.map(& &1["assignee"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&%{id: &1, name: &1})
  end

  defp labels(issues) do
    issues
    |> Enum.flat_map(& &1["labels"])
    |> Enum.uniq()
    |> Enum.map(&%{id: &1, name: &1})
  end

  defp to_issue(raw) do
    %Issue{
      id: raw["id"],
      native_ref: %{"provider" => "demo"},
      identifier: raw["identifier"],
      title: raw["title"],
      description: raw["description"],
      state: raw["native_state"],
      url: raw["url"],
      labels: raw["labels"],
      dispatchable: false,
      created_at: parse_time(raw["created_at"]),
      updated_at: parse_time(raw["updated_at"]),
      assignee_id: raw["assignee"]
    }
  end

  defp new_demo_issue(attrs, opts) do
    demo = demo(opts)
    identifier = "DEMO-#{opts |> state() |> Map.fetch!(:issues) |> length() |> Kernel.+(1)}"
    native_state = fetch_attr(attrs, :native_state) || List.first(demo.display_states) || "Todo"

    %{
      "id" => "demo-created-#{identifier}",
      "project_id" => demo.project_id,
      "revision" => 1,
      "created_at" => Map.get(attrs, :created_at, now()),
      "updated_at" => Map.get(attrs, :updated_at, now()),
      "identifier" => identifier,
      "provider" => "demo",
      "provider_id" => identifier,
      "provider_version" => "demo-1",
      "title" => fetch_attr(attrs, :title),
      "description" => fetch_attr(attrs, :description) || "",
      "native_state" => native_state,
      "display_column" => native_state,
      "assignee" => fetch_attr(attrs, :assignee_id),
      "labels" => [],
      "url" => "https://example.invalid/issue/#{identifier}",
      "capabilities" => capabilities()
    }
  end

  defp fetch_attr(attrs, key) when is_map(attrs), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  defp update_issue(opts, issue_id, fun) do
    demo_state = state(opts)

    case Enum.find_index(demo_state.issues, &(&1["id"] == issue_id)) do
      nil ->
        {:error, :not_found, %{issue_id: issue_id}}

      index ->
        issue = demo_state.issues |> Enum.at(index) |> fun.()
        Agent.update(state_name(opts), &%{&1 | issues: List.replace_at(&1.issues, index, issue)})
        {:ok, issue}
    end
  end

  defp demo_running?(opts) do
    case Process.whereis(state_name(opts)) do
      nil -> {:error, :demo_only, %{reason: "demo writes need the demonstration state to be running"}}
      _pid -> :ok
    end
  end

  defp state(opts) do
    case Process.whereis(state_name(opts)) do
      nil -> initial_state()
      _pid -> Agent.get(state_name(opts), & &1)
    end
  end

  defp state_name(opts), do: Keyword.get(opts, :demo_state, @state_name)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end
end
