defmodule SymphonyElixir.Experience.DemoAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.DemoAdapter

  setup do
    name = Module.concat(__MODULE__, :"Demo#{System.unique_integer([:positive])}")
    start_supervised!({DemoAdapter, name: name})
    %{demo: name}
  end

  test "exposes the demonstration notice and never claims provider capabilities", %{demo: demo} do
    assert DemoAdapter.notice(demo_state: demo) =~ "演示数据"

    capabilities = DemoAdapter.capabilities() |> Map.new(&{&1.name, &1})
    assert capabilities["read"].available
    refute capabilities["pause"].available
    assert capabilities["pause"].reason =~ "demo mode"

    # The demonstration state can read and update its own plan reference, but it
    # still has no real tracker to pause or resume.
    assert capabilities["workpad"].available
    assert DemoAdapter.secret_environment_names() == []
  end

  test "lists the fixture issues with their provider native states", %{demo: demo} do
    assert {:ok, issues} = DemoAdapter.list_issues(demo_state: demo)

    assert length(issues) == 8

    identifiers = Enum.map(issues, & &1.identifier)
    assert "EMB-42" in identifiers
    assert "EMB-35" in identifiers

    emb42 = Enum.find(issues, &(&1.identifier == "EMB-42"))
    assert emb42.state == "In Progress"
    assert emb42.assignee_id == "Driver Agent"
    assert emb42.labels == ["调查中"]
    assert emb42.updated_at == ~U[2026-09-14 10:38:00Z]
  end

  test "reports every configured workflow state with a display column", %{demo: demo} do
    assert {:ok, metadata} = DemoAdapter.metadata(demo_state: demo)

    assert metadata.provider == "demo"
    assert metadata.stale == false
    assert Enum.map(metadata.states, & &1.name) |> Enum.sort() == ["Done", "Human Review", "In Progress", "Todo"]
    assert Enum.all?(metadata.states, &(&1.display_column != nil))
    assert Enum.all?(metadata.states, &Map.has_key?(&1, :active))
    assert metadata.capabilities == DemoAdapter.capabilities()
    assert Enum.map(metadata.assignees, & &1.name) |> Enum.member?("Driver Agent")
    assert Enum.map(metadata.labels, & &1.name) |> Enum.member?("调查中")
  end

  test "reads one issue by id or identifier and reports a miss", %{demo: demo} do
    assert {:ok, issue} = DemoAdapter.get_issue("EMB-42", demo_state: demo)
    assert issue.identifier == "EMB-42"

    assert {:ok, same} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
    assert same.identifier == "EMB-42"

    assert {:error, :not_found, %{issue_id: "EMB-999"}} = DemoAdapter.get_issue("EMB-999", demo_state: demo)
  end

  test "creates an issue in the isolated demonstration state only", %{demo: demo} do
    assert {:ok, before} = DemoAdapter.list_issues(demo_state: demo)

    assert {:ok, created} =
             DemoAdapter.create_issue(%{title: "演示新建", description: "d", native_state: "Todo"}, demo_state: demo)

    assert created.identifier == "DEMO-#{length(before) + 1}"
    assert {:ok, issue} = DemoAdapter.get_issue(created.id, demo_state: demo)
    assert issue.title == "演示新建"
    assert issue.description == "d"

    assert {:ok, after_create} = DemoAdapter.list_issues(demo_state: demo)
    assert length(after_create) == length(before) + 1
  end

  test "transitions an issue inside the demonstration state", %{demo: demo} do
    assert {:ok, %{native_state: "Done"}} = DemoAdapter.transition("demo-issue-42", "Done", demo_state: demo)
    assert {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
    assert issue.state == "Done"

    assert {:error, :not_found, _} = DemoAdapter.transition("missing", "Done", demo_state: demo)
  end

  test "records a comment once per identical body", %{demo: demo} do
    assert {:ok, %{recorded: true}} = DemoAdapter.comment("demo-issue-42", "请看这行日志", demo_state: demo)
    assert {:ok, %{recorded: true}} = DemoAdapter.comment("demo-issue-42", "请看这行日志", demo_state: demo)
  end

  test "never invents a current plan, because the fixture has no adopted decision", %{demo: demo} do
    assert {:ok, nil} = DemoAdapter.find_operation_marker("demo-issue-42", demo_state: demo)
    assert DemoAdapter.validate_metadata(demo_state: demo) == :ok

    # The fixture's decision for EMB-40 is still a draft, so no issue has a plan
    # the executor could be running under.
    assert {:ok, nil} = DemoAdapter.get_workpad("demo-issue-40", demo_state: demo)
    assert {:ok, nil} = DemoAdapter.get_workpad("demo-issue-42", demo_state: demo)
  end

  test "updates the demonstrated plan inside the isolated state only", %{demo: demo} do
    assert {:ok, %{plan: updated}} =
             DemoAdapter.update_workpad_plan("demo-issue-42", %{plan_revision: "r14", constraints: ["稳定性优先"]}, demo_state: demo)

    assert updated["plan_revision"] == "r14"
    assert {:ok, %{plan: reread}} = DemoAdapter.get_workpad("demo-issue-42", demo_state: demo)
    assert reread["plan_revision"] == "r14"

    assert :ok = DemoAdapter.reset(demo_state: demo)
    assert {:ok, nil} = DemoAdapter.get_workpad("demo-issue-42", demo_state: demo)
  end

  test "writes are refused when the demonstration state is not running" do
    stopped = Module.concat(__MODULE__, :Stopped)

    assert {:error, :demo_only, _} = DemoAdapter.create_issue(%{title: "t"}, demo_state: stopped)
    assert {:error, :demo_only, _} = DemoAdapter.transition("id", "Done", demo_state: stopped)
    assert {:error, :demo_only, _} = DemoAdapter.comment("id", "b", demo_state: stopped)
  end

  test "reset restores the fixture", %{demo: demo} do
    {:ok, _} = DemoAdapter.transition("demo-issue-42", "Done", demo_state: demo)
    assert :ok = DemoAdapter.reset(demo_state: demo)
    assert {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
    assert issue.state == "In Progress"
  end
end
