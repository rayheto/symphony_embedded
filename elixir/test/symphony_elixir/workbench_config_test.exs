defmodule SymphonyElixir.WorkbenchConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  @data_root "/var/lib/symphony/evidence"
  @workspace_root "/var/lib/symphony/workspaces"

  defp base(workbench) do
    %{
      "tracker" => %{"kind" => "memory"},
      "workspace" => %{"root" => @workspace_root},
      "workbench" => workbench
    }
  end

  test "a workflow with no workbench section stays valid and stays disabled" do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})

    assert settings.workbench.enabled == false
    assert settings.workbench.mode == "live"
    assert settings.workbench.project_id == nil
    assert settings.workbench.display_states == []
  end

  test "an enabled workbench requires a project id and a data root" do
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(base(%{"enabled" => true}))
    assert message =~ "workbench.project_id"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(base(%{"enabled" => true, "project_id" => "embedded-lab"}))

    assert message =~ "workbench.data_root"
  end

  test "a disabled workbench may omit project id and data root" do
    assert {:ok, settings} = Schema.parse(base(%{"enabled" => false, "mode" => "demo"}))

    assert settings.workbench.enabled == false
    assert settings.workbench.mode == "demo"
  end

  test "rejects an unknown mode" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(base(%{"enabled" => false, "mode" => "staging"}))

    assert message =~ "workbench.mode"
  end

  test "rejects a repeated display state" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(
               base(%{
                 "enabled" => true,
                 "project_id" => "embedded-lab",
                 "data_root" => @data_root,
                 "display_states" => ["Todo", "In Progress", "Todo"]
               })
             )

    assert message =~ "workbench.display_states"
  end

  test "rejects a relative data root so containment can be decided exactly" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(base(%{"enabled" => true, "project_id" => "embedded-lab", "data_root" => "evidence"}))

    assert message =~ "workbench.data_root"
    assert message =~ "absolute path"
  end

  test "rejects a data root inside the workspace root" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(
               base(%{
                 "enabled" => true,
                 "project_id" => "embedded-lab",
                 "data_root" => Path.join(@workspace_root, "evidence")
               })
             )

    assert message =~ "outside workspace.root"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(base(%{"enabled" => true, "project_id" => "embedded-lab", "data_root" => @workspace_root}))

    assert message =~ "outside workspace.root"
  end

  test "accepts a fully specified workbench outside the workspace root" do
    assert {:ok, settings} =
             Schema.parse(
               base(%{
                 "enabled" => true,
                 "mode" => "live",
                 "project_id" => "embedded-lab",
                 "data_root" => @data_root,
                 "domain_profile" => "/etc/symphony/embedded-profile.yaml",
                 "device_config" => "/etc/symphony/devices.yaml",
                 "archify_root" => "/opt/archify",
                 "display_states" => ["Todo", "In Progress", "Human Review", "Done"]
               })
             )

    assert settings.workbench.enabled
    assert settings.workbench.project_id == "embedded-lab"
    assert settings.workbench.data_root == @data_root
    assert settings.workbench.display_states == ["Todo", "In Progress", "Human Review", "Done"]
  end

  test "resolves environment indirection in workbench paths" do
    System.put_env("SYMPHONY_TEST_DATA_ROOT", @data_root)
    on_exit(fn -> System.delete_env("SYMPHONY_TEST_DATA_ROOT") end)

    assert {:ok, settings} =
             Schema.parse(
               base(%{
                 "enabled" => true,
                 "project_id" => "embedded-lab",
                 "data_root" => "$SYMPHONY_TEST_DATA_ROOT"
               })
             )

    assert settings.workbench.data_root == @data_root
  end

  test "leaves optional workbench paths nil when they are not configured" do
    assert {:ok, settings} =
             Schema.parse(base(%{"enabled" => true, "project_id" => "embedded-lab", "data_root" => @data_root}))

    assert settings.workbench.domain_profile == nil
    assert settings.workbench.device_config == nil
    assert settings.workbench.archify_root == nil
  end

  test "does not run the containment check when the workspace root is relative" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "workspace" => %{"root" => "relative-workspaces"},
               "workbench" => %{
                 "enabled" => true,
                 "project_id" => "embedded-lab",
                 "data_root" => @data_root
               }
             })

    assert settings.workbench.enabled
    assert settings.workbench.data_root == @data_root
  end

  test "treats an unset environment reference as a missing data root" do
    System.delete_env("SYMPHONY_UNSET_DATA_ROOT")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(
               base(%{
                 "enabled" => true,
                 "project_id" => "embedded-lab",
                 "data_root" => "$SYMPHONY_UNSET_DATA_ROOT"
               })
             )

    assert message =~ "workbench.data_root"
  end

  test "resolves a nil path token to nil" do
    assert Schema.resolve_path_token(nil) == nil
    assert Schema.resolve_path_token("/absolute/path") == "/absolute/path"
  end

  test "parses a front matter whose values contain multi-byte characters" do
    # 待 is E5 BE 85 in UTF-8; matching a bare 0x85 byte as a line break would
    # split the character in half and fail the whole front matter.
    path = Path.join(System.tmp_dir!(), "symphony-utf8-workflow-#{System.unique_integer([:positive])}.md")

    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    workspace:
      root: "#{@workspace_root}"
    workbench:
      enabled: true
      project_id: "embedded-lab"
      data_root: "#{@data_root}"
      display_states:
        - "待办"
        - "进行中"
        - "待审阅"
        - "已完成"
    ---
    Prompt
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, workflow} = SymphonyElixir.Workflow.load(path)
    assert workflow.config["workbench"]["display_states"] == ["待办", "进行中", "待审阅", "已完成"]

    assert {:ok, settings} = Schema.parse(workflow.config)
    assert settings.workbench.display_states == ["待办", "进行中", "待审阅", "已完成"]
  end

  test "accepts workbench settings that are not a map" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{"tracker" => %{"kind" => "memory"}, "workbench" => "enabled"})
  end
end
