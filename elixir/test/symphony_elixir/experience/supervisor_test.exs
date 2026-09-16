defmodule SymphonyElixir.Experience.SupervisorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Experience.{DemoAdapter, Store, Supervisor}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-supervisor-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspace: workspace, data_root: Path.join(root, "evidence")}
  end

  defp workbench(context, overrides) do
    Map.merge(
      %{"enabled" => true, "project_id" => "embedded-lab", "data_root" => context.data_root},
      overrides
    )
  end

  defp write(context, workbench_config) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: context.workspace,
      workbench: workbench_config
    )
  end

  test "starts nothing when the workflow has no workbench section", context do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: context.workspace
    )

    assert Supervisor.children() == []
  end

  test "starts nothing when the workbench is disabled", context do
    write(context, %{"enabled" => false, "mode" => "demo"})

    assert Supervisor.children() == []
  end

  test "starts only the durable store in live mode", context do
    write(context, workbench(context, %{"mode" => "live"}))

    assert [{Store, store_opts}] = Supervisor.children()
    assert store_opts[:data_root] == context.data_root
    assert store_opts[:name] == Store
    assert is_binary(store_opts[:workspace_root])
  end

  test "adds the isolated demonstration state in demo mode", context do
    write(context, workbench(context, %{"mode" => "demo"}))

    assert [{Store, _opts}, {DemoAdapter, demo_opts}] = Supervisor.children()
    assert demo_opts == []
  end

  test "falls back to the demonstration provider when the store cannot start", context do
    # A data root the service account cannot write keeps the durable store out
    # while the isolated demonstration state still runs, so the board degrades
    # instead of the application failing to boot.
    write(context, workbench(context, %{"data_root" => "/proc/symphony-not-writable/evidence", "mode" => "demo"}))

    assert {:ok, _settings} = SymphonyElixir.Config.settings()

    assert [{DemoAdapter, []}] = Supervisor.children()
  end

  test "the supervisor starts and stops with the application", context do
    write(context, %{"enabled" => false, "mode" => "demo"})

    name = Module.concat(__MODULE__, :ExperienceSupervisor)
    assert {:ok, pid} = Elixir.Supervisor.start_link(SymphonyElixir.Experience.Supervisor, [], name: name)

    assert is_pid(pid)
    assert Elixir.Supervisor.which_children(pid) == []
    Elixir.Supervisor.stop(pid)
  end
end
