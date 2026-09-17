defmodule SymphonyElixir.Experience.ProjectTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Experience.{DemoAdapter, Project, Query, Store}

  @data_root "/var/lib/symphony/evidence"

  defp workbench(overrides) do
    Map.merge(%{"enabled" => true, "project_id" => "embedded-lab", "data_root" => @data_root}, overrides)
  end

  test "resolves the live workbench scope from the workflow settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: workbench(%{"display_states" => ["Todo", "In Progress", "Human Review", "Done"]})
    )

    assert {:ok, project} = Project.load()

    assert project.project_id == "embedded-lab"
    assert project.mode == "live"
    assert project.adapter == SymphonyElixir.Linear.WorkbenchAdapter
    assert project.store == SymphonyElixir.Experience.Store
    assert project.display_states == ["Todo", "In Progress", "Human Review", "Done"]
    assert project.data_root == @data_root
    assert Project.available?()
  end

  test "selects the isolated demonstration adapter in demo mode" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: workbench(%{"mode" => "demo"})
    )

    assert {:ok, project} = Project.load()
    assert project.adapter == DemoAdapter
    assert project.mode == "demo"
  end

  test "selects the file-backed adapter for a project whose records live in its repository" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench:
        workbench(%{
          "mode" => "files",
          "record_root" => "/srv/open-cube/ref/agent/runs",
          "bridge_tasks" => "/srv/bridge/tasks"
        })
    )

    assert {:ok, project} = Project.load()
    assert project.mode == "files"
    assert project.adapter == SymphonyElixir.Files.WorkbenchAdapter
    assert project.record_root == "/srv/open-cube/ref/agent/runs"
    assert project.bridge_tasks == "/srv/bridge/tasks"
  end

  test "reports a disabled workbench as absent rather than broken" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: %{"enabled" => false, "mode" => "demo"}
    )

    assert {:error, :workbench_disabled, %{reason: :disabled}} = Project.load()
    refute Project.available?()
  end

  test "reports a workflow with no workbench section as absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, :workbench_disabled, _} = Project.load()
  end

  test "keeps last-good settings when a reload is invalid" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: workbench(%{})
    )

    assert {:ok, _project} = Project.load()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: "invalid",
      workbench: workbench(%{})
    )

    # The invalid reload must not take the workbench down with it.
    assert {:ok, project} = Project.load()
    assert project.project_id == "embedded-lab"
  end

  test "reports an unreachable workflow as unavailable rather than absent" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: workbench(%{})
    )

    assert {:ok, _project} = Project.load()

    original = Workflow.workflow_file_path()
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    try do
      Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

      assert {:error, :workbench_unavailable, %{reason: {:missing_workflow_file, _path, _reason}}} = Project.load()
      refute Project.available?()
    after
      Workflow.set_workflow_file_path(original)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end
  end

  test "snapshot survives a stopped scheduler and reports it as unavailable" do
    root = Path.join(System.tmp_dir!(), "symphony-snapshot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Module.concat(__MODULE__, :"SnapshotStore#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: store, data_root: root})

    demo = Module.concat(__MODULE__, :"SnapshotDemo#{System.unique_integer([:positive])}")
    start_supervised!({DemoAdapter, name: demo})

    on_exit(fn -> File.rm_rf(root) end)

    project = %Project{
      project_id: "embedded-lab-demo",
      mode: "demo",
      adapter: DemoAdapter,
      store: store,
      display_states: ["待办", "进行中", "待审阅", "已完成"]
    }

    :ok = Supervisor.terminate_child(SymphonyElixir.AgentRuntimeSupervisor, SymphonyElixir.Orchestrator)

    try do
      assert {:ok, snapshot} = Query.snapshot(project, demo_state: demo)

      health = Map.new(snapshot["source_health"], &{&1["source"], &1})
      assert health["runtime"]["status"] == "unavailable"
      assert snapshot["running_count"] == 0
      assert snapshot["runtime_observed_at"] == nil
      assert snapshot["issue_count"] == 8
      assert snapshot["paused_count"] == 1
    after
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.AgentRuntimeSupervisor, SymphonyElixir.Orchestrator)
    end
  end

  test "accepts an explicit store handle for an isolated workbench" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: workbench(%{})
    )

    assert {:ok, project} = Project.load(store: :some_other_store)
    assert project.store == :some_other_store
  end
end
