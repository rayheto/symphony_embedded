defmodule SymphonyElixir.Files.WorkbenchAdapterTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Files.WorkbenchAdapter
  alias SymphonyElixir.Workflow

  setup do
    root = Path.join(System.tmp_dir!(), "files-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp handoff!(root, id, result, opts \\ []) do
    write!(
      Path.join(root, "#{id}/handoff.md"),
      """
      # Handoff `#{id}`

      - Owner Agent: #{Keyword.get(opts, :owner, "L2 C driver")}
      - Result: #{result}
      """
    )
  end

  defp bridge!(dir, name, status, payload) do
    File.mkdir_p!(dir)

    write!(
      Path.join(dir, "#{name}.json"),
      Jason.encode!(%{
        "task_name" => name,
        "status" => status,
        "claimed_by" => "/root/#{name}",
        "payload" => payload
      })
    )
  end

  defp workbench(overrides) do
    Map.merge(
      %{"enabled" => true, "project_id" => "open-cube", "data_root" => "/var/lib/symphony/evidence"},
      overrides
    )
  end

  test "only claims what it can do, and refuses every write by name", %{root: root} do
    capabilities = Map.new(WorkbenchAdapter.capabilities(), &{&1.name, &1})
    assert capabilities["read"].available
    refute capabilities["comment"].available
    assert capabilities["comment"].reason == WorkbenchAdapter.write_reason()

    for {result, capability} <- [
          {WorkbenchAdapter.create_issue(%{}, record_root: root), "create_issue"},
          {WorkbenchAdapter.transition("t1", "Done", record_root: root), "change_state"},
          {WorkbenchAdapter.comment("t1", "hi", record_root: root), "comment"}
        ] do
      assert {:error, :unsupported_capability, details} = result
      assert details.capability == capability
      assert details.mode == "files"
    end

    assert WorkbenchAdapter.secret_environment_names() == []
  end

  test "lists the project's own records as issues", %{root: root} do
    handoff!(root, "l2_cst9217_touch_e4c8", "complete")
    handoff!(root, "p4_eaf_full_pass_7b31", "partial", owner: "DeepSeek child")

    assert {:ok, issues} = WorkbenchAdapter.list_issues(record_root: root)

    assert Enum.map(issues, & &1.identifier) == ["l2_cst9217_touch_e4c8", "p4_eaf_full_pass_7b31"]

    touch = Enum.find(issues, &(&1.identifier == "l2_cst9217_touch_e4c8"))
    assert touch.id == "l2_cst9217_touch_e4c8"
    assert touch.state == "complete"
    assert touch.assignee_id == "L2 C driver"
    assert touch.labels == ["L2"]
    assert touch.dispatchable == false
    assert touch.url == nil
    assert touch.native_ref["provider"] == "files"
    assert touch.native_ref["sources"] == [Path.join(root, "l2_cst9217_touch_e4c8/handoff.md")]
    assert %DateTime{} = touch.updated_at
    assert %DateTime{} = touch.created_at
    assert touch.native_ref["bridge"] == nil
  end

  test "a bridge-only task is labelled as such and carries the bridge lifecycle", %{root: root} do
    bridge = Path.join(root, "bridge")
    bridge!(bridge, "p4_eaf_full_pass_7b31", "completed", "work in /repo/open-cube")

    assert {:ok, issues} =
             WorkbenchAdapter.list_issues(record_root: root, bridge_tasks: bridge, bridge_marker: "open-cube")

    assert [issue] = issues
    assert issue.state == "delivered"
    assert issue.assignee_id == "p4_eaf_full_pass_7b31"
    assert issue.labels == ["桥接"]

    assert issue.native_ref["bridge"] == %{
             "status" => "completed",
             "task_id" => nil,
             "claimed_by" => "p4_eaf_full_pass_7b31",
             "created_at" => nil,
             "updated_at" => nil
           }
  end

  test "a record with no readable file time reports no times rather than a guess", %{root: root} do
    File.ln_s!(Path.join(root, "gone.md"), Path.join(root, "t1.handoff.md"))

    assert {:ok, [issue]} = WorkbenchAdapter.list_issues(record_root: root)
    assert issue.state == "unreadable"
    assert issue.created_at == nil
    assert issue.updated_at == nil
  end

  test "finds one record by id and reports a miss as not found", %{root: root} do
    handoff!(root, "t1", "complete")

    assert {:ok, issue} = WorkbenchAdapter.get_issue("t1", record_root: root)
    assert issue.identifier == "t1"

    assert {:error, :not_found, %{issue_id: "nope"}} =
             WorkbenchAdapter.get_issue("nope", record_root: root)
  end

  test "reports every state with its board column and its flags", %{root: root} do
    handoff!(root, "t1", "complete")
    handoff!(root, "t2", "partial")
    handoff!(root, "t3", "whatever-this-means")

    assert {:ok, metadata} =
             WorkbenchAdapter.metadata(
               record_root: root,
               project_id: "open-cube",
               display_states: ["待办", "进行中", "待审阅", "已完成"]
             )

    assert metadata.provider == "files"
    assert metadata.provider_project_id == "open-cube"
    assert metadata.stale == false
    assert is_binary(metadata.fetched_at)
    assert metadata.capabilities == WorkbenchAdapter.capabilities()

    columns = Map.new(metadata.states, &{&1.name, &1})

    # The complete record is finished; everything else needs a person, because a
    # verdict this reader cannot read is not a reason to call it in progress.
    assert columns["complete"].terminal
    assert columns["complete"].display_column == "已完成"
    refute columns["delivered"].active
    refute columns["delivered"].terminal
    assert columns["delivered"].display_column == "待审阅"
    assert columns["open"].active
    assert columns["open"].display_column == "进行中"
    assert columns["claimed"].active
    assert columns["partial"].display_column == "待审阅"
    assert columns["unreadable"].display_column == "待审阅"

    assert Enum.map(metadata.assignees, & &1.id) == ["L2 C driver"]
    assert metadata.labels == []
  end

  test "an unconfigured record root is reported, not served as an empty board" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workbench: workbench(%{}))

    assert {:error, :record_root_missing, details} = WorkbenchAdapter.list_issues()
    assert details.reason =~ "record_root"

    assert {:error, :record_root_missing, _details} = WorkbenchAdapter.metadata()
    assert {:error, :record_root_missing, _details} = WorkbenchAdapter.get_issue("t1")
  end

  test "an unreadable record root is reported with its reason", %{root: root} do
    absent = Path.join(root, "absent")

    assert {:error, :record_root_unreadable, %{root: ^absent, reason: :enoent}} =
             WorkbenchAdapter.list_issues(record_root: absent)
  end

  test "reads the configured roots and the project marker from the workflow", %{root: root} do
    bridge = Path.join(root, "bridge")
    handoff!(root, "t1", "complete")
    bridge!(bridge, "mine", "completed", "work in /repo/open-cube")
    bridge!(bridge, "theirs", "completed", "work in /repo/other")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workbench:
        workbench(%{
          "mode" => "files",
          "record_root" => root,
          "bridge_tasks" => bridge,
          "bridge_task_marker" => "open-cube"
        })
    )

    assert WorkbenchAdapter.record_root() == root
    assert WorkbenchAdapter.bridge_tasks() == bridge
    assert WorkbenchAdapter.bridge_marker() == "open-cube"

    assert {:ok, issues} = WorkbenchAdapter.list_issues()
    assert Enum.map(issues, & &1.identifier) == ["mine", "t1"]

    # An explicit option still wins over the workflow, so a one-off call can
    # point anywhere: the other root's record is read instead of the configured
    # one. The bridge still comes from the workflow, which is why an option only
    # overrides what it names.
    other = Path.join(root, "other")
    handoff!(other, "elsewhere", "complete")

    assert {:ok, issues} = WorkbenchAdapter.list_issues(record_root: other)
    identifiers = Enum.map(issues, & &1.identifier)
    assert "elsewhere" in identifiers
    refute "t1" in identifiers
  end

  test "a bridge record's own times are carried into the issue reference", %{root: root} do
    bridge = Path.join(root, "bridge")
    File.mkdir_p!(bridge)

    write!(
      Path.join(bridge, "dated.json"),
      Jason.encode!(%{
        "task_name" => "dated",
        "status" => "completed",
        "claimed_by" => "/root/dated",
        "task_id" => "abc123",
        "created_at" => "2026-09-16T03:36:39.876464Z",
        "updated_at" => "2026-09-16T22:15:21.865908Z"
      })
    )

    assert {:ok, [issue]} = WorkbenchAdapter.list_issues(record_root: root, bridge_tasks: bridge)
    ref = issue.native_ref["bridge"]

    assert ref["task_id"] == "abc123"
    assert ref["created_at"] == "2026-09-16T03:36:39.876464Z"
    assert ref["updated_at"] == "2026-09-16T22:15:21.865908Z"
  end
end
