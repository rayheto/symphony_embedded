defmodule SymphonyElixir.Experience.QueryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.{Cursor, DemoAdapter, Project, Query, Store}
  alias SymphonyElixir.Tracker.Issue

  @project_id "embedded-lab-demo"
  @display_states ["待办", "进行中", "待审阅", "已完成"]

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-query-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: store, data_root: root})

    demo = Module.concat(__MODULE__, :"Demo#{System.unique_integer([:positive])}")
    start_supervised!({DemoAdapter, name: demo})

    on_exit(fn -> File.rm_rf(root) end)

    %{store: store, demo: demo}
  end

  defp project(context, overrides \\ []) do
    struct!(
      %Project{
        project_id: @project_id,
        mode: "demo",
        adapter: DemoAdapter,
        store: context.store,
        display_states: @display_states,
        workspace_root: "/tmp/workspaces"
      },
      overrides
    )
  end

  defp opts(context, extra \\ []) do
    Keyword.merge([demo_state: context.demo, runtime_snapshot: fn -> %{running_count: 3, paused_count: 1} end], extra)
  end

  test "lists issues in display-column order with the board filters applied", %{store: store} = context do
    assert {:ok, page} = Query.list_issues(project(context), %{}, opts(context))
    assert length(page.items) == 8
    assert page.next_cursor == nil

    columns = page.items |> Enum.map(& &1["display_column"]) |> Enum.uniq()
    assert columns == ["待办", "进行中", "待审阅", "已完成"]

    assert page.items |> hd() |> Map.get("display_column") == "待办"
    assert store == context.store
  end

  test "filters by identifier, state, assignee and column", %{store: store} = context do
    assert {:ok, page} = Query.list_issues(project(context), %{q: "EMB-42"}, opts(context))
    assert Enum.map(page.items, & &1["identifier"]) == ["EMB-42"]

    assert {:ok, page} = Query.list_issues(project(context), %{column: "待审阅"}, opts(context))
    assert Enum.map(page.items, & &1["identifier"]) == ["EMB-40"]

    assert {:ok, page} = Query.list_issues(project(context), %{assignee: "Hardware Agent"}, opts(context))
    assert Enum.map(page.items, & &1["identifier"]) == ["EMB-46"]

    assert {:ok, page} = Query.list_issues(project(context), %{state: "Done"}, opts(context))
    assert Enum.map(page.items, & &1["identifier"]) == ["EMB-35"]

    assert {:ok, empty} = Query.list_issues(project(context), %{q: "nothing-matches"}, opts(context))
    assert empty.items == []
    assert store == context.store
  end

  test "paginates and expires a cursor reused with different filters", %{store: store} = context do
    assert {:ok, first} = Query.list_issues(project(context), %{limit: 3}, opts(context))
    assert length(first.items) == 3
    assert is_binary(first.next_cursor)

    assert {:ok, second} = Query.list_issues(project(context), %{limit: 3, cursor: first.next_cursor}, opts(context))
    assert length(second.items) == 3

    first_ids = Enum.map(first.items, & &1["id"])
    second_ids = Enum.map(second.items, & &1["id"])
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))

    assert {:error, :cursor_expired, %{changed: ["filters"]}} =
             Query.list_issues(project(context), %{limit: 3, q: "EMB", cursor: first.next_cursor}, opts(context))

    assert {:error, :invalid_cursor, _} =
             Query.list_issues(project(context), %{cursor: "%%%"}, opts(context))

    assert store == context.store
  end

  test "reports column counts for the board header", %{store: store} = context do
    assert {:ok, counts} = Query.column_counts(project(context), %{}, opts(context))
    assert counts == [{"待办", 3}, {"进行中", 3}, {"待审阅", 1}, {"已完成", 1}]

    # EMB-4 matches three Todo cards, one In Progress card and one review card.
    assert {:ok, filtered} = Query.column_counts(project(context), %{q: "EMB-4"}, opts(context))
    assert Map.new(filtered) == %{"待办" => 3, "进行中" => 1, "待审阅" => 1, "已完成" => 0}

    assert store == context.store
  end

  test "reads one issue and rejects an unknown one", %{store: store} = context do
    assert {:ok, view} = Query.get_issue(project(context), "EMB-42", opts(context))
    assert view.identifier == "EMB-42"
    assert view.display_column == "进行中"

    assert {:ok, same} = Query.get_issue(project(context), "demo-issue-42", opts(context))
    assert same.identifier == "EMB-42"

    assert {:error, :not_found, %{issue_id: "EMB-999"}} = Query.get_issue(project(context), "EMB-999", opts(context))
    assert store == context.store
  end

  test "builds an issue context pointing at the runtime view", %{store: store} = context do
    assert {:ok, issue} = Query.get_issue(project(context), "EMB-42", opts(context))
    {:ok, _} = Store.append(@project_id, "ProblemCase", "pc-1", 0, %{"issue_ids" => [issue.id]}, nil, server: store)
    {:ok, _} = Store.append(@project_id, "Evidence", "ev-1", 0, %{"issue_ids" => [issue.id]}, nil, server: store)
    {:ok, _} = Store.append(@project_id, "Evidence", "ev-2", 0, %{"issue_ids" => ["other"]}, nil, server: store)

    assert {:ok, context_map} = Query.issue_context(project(context), "EMB-42", opts(context))

    assert context_map["issue_id"] == issue.id
    assert context_map["problem_case_ids"] == ["pc-1"]
    assert context_map["evidence_ids"] == ["ev-1"]
    assert context_map["runtime_snapshot_url"] == "/api/v1/EMB-42"
    assert context_map["provider_workpad_url"] == view_url(context)
  end

  defp view_url(%{demo: demo}) do
    {:ok, issues} = DemoAdapter.list_issues(demo_state: demo)
    Enum.find(issues, &(&1.identifier == "EMB-42")).url
  end

  test "reports an unavailable change view instead of inventing a diff", %{store: store} = context do
    assert {:ok, changes} = Query.changes(project(context), "EMB-42", opts(context))

    assert changes["status"] == "unavailable"
    assert changes["changed_paths"] == []
    assert changes["limitations"] != []
    assert store == context.store

    source = fn view -> {:ok, %{"issue_id" => view.id, "status" => "available", "changed_paths" => ["lib/a.c"]}} end

    assert {:ok, %{"status" => "available"}} = Query.changes(project(context), "EMB-42", opts(context, changes_source: source))
  end

  test "exposes provider metadata and capabilities", %{store: store} = context do
    assert {:ok, metadata} = Query.provider_metadata(project(context), opts(context))

    assert metadata["provider"] == "demo"
    assert metadata["project_id"] == @project_id
    assert Enum.all?(metadata["states"], &(&1.display_column != nil))
    assert store == context.store
  end

  test "lists and reads stored engineering entities, rejecting unknown types", %{store: store} = context do
    {:ok, _} = Store.append(@project_id, "Evidence", "ev-1", 0, %{"title" => "片段"}, nil, server: store)

    assert {:ok, [record]} = Query.list_entities(project(context), "Evidence", opts(context))
    assert record.entity_id == "ev-1"

    assert {:ok, payload} = Query.get_entity(project(context), "Evidence", "ev-1", opts(context))
    assert payload["title"] == "片段"
    assert payload["revision"] == 1

    assert {:error, :not_found, %{entity_id: "missing"}} = Query.get_entity(project(context), "Evidence", "missing", opts(context))

    assert {:error, :unsupported_entity_type, %{entity_type: "Ticket"}} =
             Query.list_entities(project(context), "Ticket", opts(context))
  end

  test "replays events after a cursor", %{store: store} = context do
    {:ok, _} = Store.emit_event(@project_id, "evidence.registered", "Evidence", "ev-1", server: store, run_id: "run-7")
    {:ok, _} = Store.emit_event(@project_id, "plan.loaded", "Decision", "dec-1", server: store, run_id: "run-7")

    assert {:ok, page} = Query.events(project(context), %{}, opts(context))
    assert Enum.map(page["items"], & &1["type"]) == ["evidence.registered", "plan.loaded"]
    assert page["next_cursor"] == 2
    assert page["snapshot_seq"] == 2

    assert {:ok, later} = Query.events(project(context), %{after_seq: 1}, opts(context))
    assert Enum.map(later["items"], & &1["type"]) == ["plan.loaded"]

    assert {:ok, empty} = Query.events(project(context), %{after_seq: 99}, opts(context))
    assert empty["items"] == []
    assert empty["next_cursor"] == 99
  end

  test "snapshot separates tracker, runtime and store freshness", %{store: store} = context do
    assert {:ok, snapshot} = Query.snapshot(project(context), opts(context))

    assert snapshot["project_id"] == @project_id
    assert snapshot["issue_count"] == 8
    assert snapshot["running_count"] == 3
    assert snapshot["paused_count"] == 1
    assert snapshot["review_count"] == 1
    assert snapshot["snapshot_seq"] == Store.project_seq(@project_id, server: store)

    health = Map.new(snapshot["source_health"], &{&1["source"], &1})
    assert health["tracker"]["status"] == "healthy"
    assert health["runtime"]["status"] == "healthy"
    assert health["store"]["status"] == "healthy"
    assert is_binary(snapshot["tracker_fetched_at"])
    assert is_binary(snapshot["runtime_observed_at"])
  end

  test "snapshot marks a tracker failure as degraded without hiding the reason", %{store: store} = context do
    failing = project(context, adapter: __MODULE__.FailingAdapter)

    assert {:ok, snapshot} = Query.snapshot(failing, opts(context))

    health = Map.new(snapshot["source_health"], &{&1["source"], &1})
    assert health["tracker"]["status"] == "degraded"
    assert health["tracker"]["detail"] =~ "not_found"
    assert snapshot["tracker_fetched_at"] == nil
    assert snapshot["issue_count"] == 0
    assert store == context.store
  end

  test "runtime counts are omitted when the orchestrator cannot answer", %{store: store} = context do
    assert {:ok, snapshot} = Query.snapshot(project(context), demo_state: context.demo, runtime_snapshot: fn -> nil end)

    health = Map.new(snapshot["source_health"], &{&1["source"], &1})
    assert health["runtime"]["status"] == "unavailable"
    assert snapshot["runtime_observed_at"] == nil
    assert snapshot["running_count"] == 0
    assert store == context.store
  end

  defmodule FailingAdapter do
    @moduledoc false

    def metadata(_opts), do: {:error, :not_found, %{reason: "no provider"}}
    def list_issues(_opts), do: {:error, :not_found, %{reason: "no provider"}}
    def get_issue(_id, _opts), do: {:error, :not_found, %{reason: "no provider"}}
  end

  test "an issue view survives a provider with no usable state metadata", %{store: store} = context do
    adapter = __MODULE__.NoMetadataAdapter
    project = project(context, adapter: adapter)

    assert {:ok, view} = Query.get_issue(project, "EMB-42", opts(context))

    # Without state metadata the state cannot be active or terminal, so it lands
    # in the review column instead of being invented into a board column.
    assert view.display_column == "待审阅"

    assert {:ok, page} = Query.list_issues(project, %{}, opts(context))
    assert Enum.all?(page.items, &(&1["display_column"] == "待审阅"))
    assert store == context.store
  end

  defmodule NoMetadataAdapter do
    @moduledoc false

    def metadata(_opts), do: {:error, :unsupported_capability, %{capability: "read"}}

    def list_issues(_opts) do
      {:ok,
       [
         %Issue{
           id: "issue-1",
           identifier: "EMB-42",
           title: "t",
           state: "In Progress",
           updated_at: ~U[2026-09-14 10:38:00Z]
         }
       ]}
    end

    def get_issue(id, opts) do
      with {:ok, issues} <- list_issues(opts) do
        case Enum.find(issues, &(&1.id == id or &1.identifier == id)) do
          nil -> {:error, :not_found, %{issue_id: id}}
          issue -> {:ok, issue}
        end
      end
    end
  end

  test "an identifier lookup falls back to a provider scan", %{store: store} = context do
    adapter = __MODULE__.IdentifierOnlyAdapter

    assert {:ok, view} = Query.get_issue(project(context, adapter: adapter), "EMB-42", opts(context))
    assert view.identifier == "EMB-42"

    assert {:error, :not_found, _} = Query.get_issue(project(context, adapter: adapter), "EMB-999", opts(context))
    assert store == context.store
  end

  defmodule IdentifierOnlyAdapter do
    @moduledoc false

    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def get_issue(_id, _opts), do: {:error, :not_found, %{issue_id: nil}}

    def list_issues(_opts) do
      {:ok,
       [
         %Issue{
           id: "issue-1",
           identifier: "EMB-42",
           title: "t",
           state: "In Progress",
           updated_at: ~U[2026-09-14 10:38:00Z]
         }
       ]}
    end
  end

  test "every entry point works through its default options" do
    context = %{
      store: retry_store(),
      demo: SymphonyElixir.Experience.DemoAdapter.State
    }

    project = project(context)

    # With no options the query falls back to the demonstration fixture, which
    # is what a demo deployment without an explicit state handle sees.
    assert {:ok, snapshot} = Query.snapshot(project)
    assert snapshot["project_id"] == @project_id

    assert {:ok, page} = Query.list_issues(project, %{})
    assert length(page.items) == 8

    assert {:ok, view} = Query.get_issue(project, "EMB-42")
    assert view.identifier == "EMB-42"

    assert {:ok, context_map} = Query.issue_context(project, "EMB-42")
    assert context_map["issue_id"] == view.id

    assert {:ok, changes} = Query.changes(project, "EMB-42")
    assert changes["status"] == "unavailable"

    assert {:ok, metadata} = Query.provider_metadata(project)
    assert metadata["provider"] == "demo"

    assert {:ok, []} = Query.list_entities(project, "Evidence")
    assert {:ok, events} = Query.events(project, %{})
    assert events["items"] == []

    assert {:ok, counts} = Query.column_counts(project)
    assert counts == [{"待办", 3}, {"进行中", 3}, {"待审阅", 1}, {"已完成", 1}]

    assert {:ok, counts} = Query.column_counts(project, %{q: "EMB-42"})
    assert Map.new(counts)["进行中"] == 1

    assert {:error, :unsupported_entity_type, _} = Query.list_entities(project, "Nope")
  end

  defp retry_store do
    root = Path.join(System.tmp_dir!(), "symphony-query-default-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = Module.concat(__MODULE__, :"DefaultStore#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, data_root: root})
    on_exit(fn -> File.rm_rf(root) end)
    name
  end

  test "reports provider failures through list_issues and get_entity", %{store: store} = context do
    failing = project(context, adapter: __MODULE__.FailingAdapter)

    assert {:error, :not_found, %{reason: "no provider"}} = Query.list_issues(failing, %{}, opts(context))

    assert {:ok, _} = Store.append(@project_id, "Evidence", "ev-1", 0, %{"title" => "t"}, nil, server: store)

    assert {:error, :unsupported_entity_type, _} = Query.get_entity(project(context), "Nope", "ev-1", opts(context))

    assert {:ok, payload} = Query.get_entity(project(context), "Evidence", "ev-1", opts(context))
    assert payload["title"] == "t"
  end

  test "surfaces a permission failure as an unavailable tracker", %{store: store} = context do
    denied = project(context, adapter: __MODULE__.DeniedAdapter)

    assert {:ok, snapshot} = Query.snapshot(denied, opts(context))

    health = Map.new(snapshot["source_health"], &{&1["source"], &1})
    assert health["tracker"]["status"] == "unavailable"
    assert store == context.store
  end

  defmodule DeniedAdapter do
    @moduledoc false

    def metadata(_opts), do: {:error, :permission_denied, %{status: 401}}
    def list_issues(_opts), do: {:error, :permission_denied, %{status: 401}}
    def get_issue(_id, _opts), do: {:error, :permission_denied, %{status: 401}}
  end

  test "clamps a nonsensical page limit back to the default", %{store: store} = context do
    assert {:ok, page} = Query.list_issues(project(context), %{limit: 0}, opts(context))
    assert length(page.items) == 8

    assert {:ok, page} = Query.list_issues(project(context), %{limit: "many"}, opts(context))
    assert length(page.items) == 8

    assert {:ok, page} = Query.list_issues(project(context), %{limit: 500}, opts(context))
    assert length(page.items) == 8
    assert store == context.store
  end

  test "reads the plan reference from a workpad when the provider has one", %{store: store} = context do
    adapter = __MODULE__.WorkpadAdapter
    plan_project = project(context, adapter: adapter)

    assert {:ok, context_map} = Query.issue_context(plan_project, "EMB-42", opts(context))
    plan = context_map["current_plan"]

    assert plan["decision_id"] == "dec-1"
    assert plan["decision_revision"] == 3
    assert plan["plan_revision"] == "r13"
    assert plan["workpad_url"] == "https://example.invalid/EMB-42"
    assert plan["project_id"] == @project_id
    assert String.length(plan["plan_sha256"]) == 64
    assert store == context.store
  end

  test "reports no plan when the provider exposes no workpad reader", %{store: store} = context do
    adapter = __MODULE__.NoMetadataAdapter

    assert {:ok, context_map} = Query.issue_context(project(context, adapter: adapter), "EMB-42", opts(context))
    assert context_map["current_plan"] == nil
    assert store == context.store
  end

  defmodule WorkpadAdapter do
    @moduledoc false

    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, [issue()]}

    def get_issue(id, _opts) do
      if id == "EMB-42", do: {:ok, issue()}, else: {:error, :not_found, %{issue_id: id}}
    end

    def get_workpad(_id, _opts) do
      {:ok,
       %{
         id: "comment-2",
         plan: %{
           "decision_id" => "dec-1",
           "decision_revision" => 3,
           "decision_sha256" => String.duplicate("a", 64),
           "plan_revision" => "r13",
           "constraints" => ["稳定性优先"],
           "remaining_validation" => ["真机复测"]
         }
       }}
    end

    defp issue do
      %Issue{
        id: "issue-1",
        identifier: "EMB-42",
        title: "t",
        state: "In Progress",
        url: "https://example.invalid/EMB-42",
        updated_at: ~U[2026-09-14 10:38:00Z]
      }
    end
  end

  test "defaults a missing page limit and an unbounded one", %{store: store} = context do
    assert {:ok, page} = Query.list_issues(project(context), %{limit: nil}, opts(context))
    assert length(page.items) == 8
    assert store == context.store
  end

  test "reads an entity through its default options and reports provider write errors", %{store: store} = context do
    {:ok, _} = Store.append(@project_id, "Evidence", "ev-1", 0, %{"title" => "t"}, nil, server: store)

    assert {:ok, payload} = Query.get_entity(project(context), "Evidence", "ev-1")
    assert payload["title"] == "t"

    erroring = project(context, adapter: __MODULE__.LookupErrorAdapter)
    assert {:error, :provider_unavailable, %{}} = Query.get_issue(erroring, "EMB-42", opts(context))
    assert store == context.store
  end

  defmodule LookupErrorAdapter do
    @moduledoc false

    def metadata(_opts), do: {:error, :provider_unavailable, %{}}
    def list_issues(_opts), do: {:error, :provider_unavailable, %{}}
    def get_issue(_id, _opts), do: {:error, :provider_unavailable, %{}}
  end

  test "keeps reading when the store cannot answer for the sequence", %{demo: demo, store: store} do
    broken = project(%{store: :missing_store, demo: demo})

    assert {:ok, snapshot} = Query.snapshot(broken, demo_state: demo)
    assert snapshot["snapshot_seq"] == 0
    assert store != :missing_store
  end

  test "derives a display column for provider states that carry none" do
    context = %{store: retry_store(), demo: SymphonyElixir.Experience.DemoAdapter.State}
    adapter = __MODULE__.NoColumnAdapter

    assert {:ok, page} = Query.list_issues(project(context, adapter: adapter), %{}, demo_state: context.demo)
    assert Enum.map(page.items, & &1["display_column"]) == ["进行中"]
  end

  defmodule NoColumnAdapter do
    @moduledoc false

    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [%{id: "s-1", name: "In Progress", active: true, terminal: false}],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, [%Issue{id: "i-1", identifier: "EMB-42", title: "t", state: "In Progress"}]}
    def get_issue(id, opts), do: if(id == "EMB-42", do: {:ok, hd(elem(list_issues(opts), 1))}, else: {:error, :not_found, %{}})
  end

  test "cursor encode and validate round-trip through the public API" do
    cursor = Cursor.encode(%{"project_id" => "p", "filters" => "f", "offset" => 10})

    assert {:ok, decoded} = Cursor.decode(cursor)
    assert :ok = Cursor.validate(decoded, %{"project_id" => "p", "filters" => "f"})
  end
end
