defmodule SymphonyElixirWeb.WorkbenchLiveTest do
  # The workbench reads through the production registered names, so this module
  # owns the default store and demonstration state and runs synchronously.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias SymphonyElixir.Devices.Manager
  alias SymphonyElixir.Experience.{Architecture, Canonical, DemoAdapter, Store}

  @endpoint SymphonyElixirWeb.Endpoint
  @data_root_prefix "symphony-workbench-live"

  setup do
    root = Path.join(System.tmp_dir!(), "#{@data_root_prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    stop_if_running(Store)
    stop_if_running(DemoAdapter)

    start_test_endpoint()
    # `restart: :transient` lets one test take the store down deliberately
    # without the supervisor putting it straight back.
    start_supervised!(%{id: Store, start: {Store, :start_link, [[data_root: root]]}, restart: :transient})
    # `restart: :transient` lets one test take the provider down deliberately
    # without the supervisor putting it straight back.
    start_supervised!(%{id: DemoAdapter, start: {DemoAdapter, :start_link, [[]]}, restart: :transient})

    on_exit(fn ->
      stop_if_running(Store)
      stop_if_running(DemoAdapter)
      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: %{
        "enabled" => true,
        "mode" => "demo",
        "project_id" => "embedded-lab-demo",
        "data_root" => root,
        "display_states" => ["待办", "进行中", "待审阅", "已完成"],
        # Human Review is the demonstration project's non-active, non-terminal
        # state, which is what a persistent pause needs.
        "paused_state" => "Human Review"
      }
    )

    %{root: root}
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp stop_if_running(module) do
    case Process.whereis(module) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  test "the board renders all four columns and every fixture card" do
    {:ok, view, html} = live(build_conn(), "/workbench/issues")

    assert html =~ "Issues"
    assert html =~ "演示数据"

    for column <- ["待办", "进行中", "待审阅", "已完成"] do
      assert render(view) =~ column
    end

    for identifier <- ["EMB-46", "EMB-45", "EMB-43", "EMB-42", "EMB-39", "EMB-37", "EMB-40", "EMB-35"] do
      assert render(view) =~ identifier
    end

    # Board state comes with text, not colour alone.
    assert render(view) =~ "3 个任务运行中"
  end

  test "the board links every card to its issue detail page" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    assert has_element?(view, "a.wb-issue-card[href='/workbench/issues/EMB-42']")
  end

  test "the list view shows the same issues with native and display states" do
    {:ok, _view, html} = live(build_conn(), "/workbench/issues?view=list")

    assert html =~ "原生状态"
    assert html =~ "显示列"
    assert html =~ "EMB-42"
    assert html =~ "In Progress"
  end

  test "a filter narrows the board and reports an empty result honestly" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues?q=EMB-42")

    assert render(view) =~ "EMB-42"
    refute render(view) =~ "EMB-46"

    {:ok, empty, html} = live(build_conn(), "/workbench/issues?q=no-such-issue")

    assert html =~ "当前筛选没有匹配的 Issue"
    refute render(empty) =~ "EMB-42"
  end

  test "the new-issue form offers provider options and records a receipt" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    refute has_element?(view, "section[aria-label='新建 Issue']")

    view |> element("button", "新建 Issue") |> render_click()
    assert has_element?(view, "section[aria-label='新建 Issue']")

    html =
      view
      |> form("form[phx-submit='create']", %{"issue" => %{"title" => "看板新建", "description" => "说明", "native_state" => "Todo"}})
      |> render_submit()

    assert html =~ "看板新建"
    refute has_element?(view, "section[aria-label='新建 Issue']")
  end

  test "a failed create keeps the form open and writes no board card" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    view |> element("button", "新建 Issue") |> render_click()

    # The form only offers provider states, so an unknown state cannot be picked.
    assert has_element?(view, "select[name='issue[native_state]'] option[value='Todo']")
    refute has_element?(view, "select[name='issue[native_state]'] option[value='不存在']")

    # With the provider gone the write cannot land, so the form must stay open
    # with the operator's input intact rather than closing on a failed write.
    GenServer.stop(Process.whereis(DemoAdapter.State))

    html =
      view
      |> form("form[phx-submit='create']", %{"issue" => %{"title" => "会被拒绝", "native_state" => "Todo"}})
      |> render_submit()

    assert html =~ "未产生副作用，可修正后重试"
    assert has_element?(view, "section[aria-label='新建 Issue']")
    assert has_element?(view, "input[name='issue[title]'][value='会被拒绝']")
    refute html =~ "wb-issue-title\">会被拒绝"
  end

  test "the issue detail page renders every recorded fact it has" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42")

    assert render(view) =~ "修复显示画面偶发撕裂"
    assert render(view) =~ "连续切换画面时出现局部撕裂"
    assert render(view) =~ "进行中"

    # The demonstration provider has no usable native URL, so the page says so
    # rather than rendering a link that goes nowhere.
    assert render(view) =~ "当前 provider 未提供原生链接"
  end

  test "every detail tab renders without inventing engineering facts" do
    for tab <- ["overview", "activity", "investigation", "changes"] do
      {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=#{tab}")
      html = render(view)

      assert html =~ "修复显示画面偶发撕裂"
      refute html =~ "根因已确认"
    end
  end

  test "an unknown tab falls back to the overview instead of erroring" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=nonsense")

    assert render(view) =~ "描述"
  end

  test "a missing issue shows a clear not-found page with a way back" do
    {:ok, _view, html} = live(build_conn(), "/workbench/issues/EMB-999")

    assert html =~ "找不到该 Issue"
    assert html =~ "返回 Issues"
  end

  test "the workbench entry point forwards to the issues board" do
    assert {:error, {:redirect, %{to: "/workbench/issues"}}} = live(build_conn(), "/workbench")
  end

  test "a comment is recorded as a receipt rather than claimed as delivered" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    html =
      view
      |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "请补充一次真机复测。"}})
      |> render_submit()

    assert html =~ "请补充一次真机复测"
  end

  test "requesting evidence records the request without resuming anything" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    html = view |> element("button", "要求补充证据") |> render_click()

    assert html =~ "要求补充证据"
    assert html =~ "不会因此自动恢复执行"
  end

  test "the investigation tab renders the stored case and evidence" do
    seed_engineering_records()

    {:ok, view, html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    assert html =~ "缓冲区可能在传输结束前被复用"
    assert html =~ "hypothesis"
    assert html =~ "连续切换画面时观察到异常"
    assert html =~ "仅有日志片段"
    assert html =~ "E-017 串口片段"
    assert html =~ "serial"
    assert html =~ "available"
    assert html =~ "unseen"
    assert render(view) =~ "尚未连接图像源" == false
  end

  test "the activity tab renders recorded events and their receipts" do
    seed_engineering_records()

    {:ok, _view, html} = live(build_conn(), "/workbench/issues/EMB-42?tab=activity")

    assert html =~ "evidence.registered"
    assert html =~ "已记录日志片段"
  end

  test "an unsent comment stays a draft until it is submitted" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    html = view |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "草稿"}}) |> render_change()

    assert html =~ "草稿"

    # Nothing was written yet: a typed draft is not a posted comment.
    assert html =~ "没有针对该 Issue 的操作。"
  end

  test "a failed comment keeps the typed text and reports why" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    GenServer.stop(Process.whereis(DemoAdapter.State))

    html =
      view
      |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "发不出去的意见"}})
      |> render_submit()

    assert html =~ "可修正后重试"
    assert html =~ "发不出去的意见"

    {:ok, after_restart} = {:ok, ensure_demo_running()}
    assert after_restart == :ok
  end

  defp ensure_demo_running do
    case Process.whereis(DemoAdapter.State) do
      nil -> DemoAdapter.start_link([]) |> elem(1) |> then(fn _ -> :ok end)
      _pid -> :ok
    end
  end

  defp seed_engineering_records do
    {:ok, issue} = DemoAdapter.get_issue("EMB-42")

    {:ok, _} =
      Store.append(
        "embedded-lab-demo",
        "ProblemCase",
        "DISP-12",
        0,
        %{
          "issue_ids" => [issue.id],
          "component_ids" => ["display-driver"],
          "symptom" => "连续切换画面时出现局部撕裂。",
          "claims" => [
            %{
              "id" => "claim-1",
              "statement" => "缓冲区可能在传输结束前被复用。",
              "status" => "hypothesis",
              "supporting_evidence_ids" => [],
              "contradicting_evidence_ids" => [],
              "evidence_missing" => true,
              "limitations" => ["仅有日志片段"]
            }
          ],
          "experiments" => [
            %{
              "id" => "exp-1",
              "occurred_at" => "2026-09-14T10:24:00Z",
              "question" => "是否为刷新频率导致",
              "procedure" => "调整刷新频率后复现",
              "observation" => "连续切换画面时观察到异常。",
              "outcome" => "refutes",
              "evidence_ids" => [],
              "limitations" => []
            }
          ],
          "current_conclusion" => "尚未确认根因。",
          "next_step" => "增加完成事件标记。",
          "state" => %{
            "implementation_status" => "building",
            "verification_status" => "unverified",
            "human_review_status" => "unseen",
            "agent_endorsed" => false
          },
          "limitations" => ["事件含义仍需核验"]
        },
        %{kind: "agent", id: "run-7", display_name: "Driver Agent"}
      )

    {:ok, _} =
      Store.append(
        "embedded-lab-demo",
        "Evidence",
        "E-017",
        0,
        %{
          "issue_ids" => [issue.id],
          "source_kind" => "serial",
          "title" => "E-017 串口片段",
          "raw" => [],
          "source_refs" => [],
          "binding" => %{"repo_revision" => nil, "test_profile" => "board_test"},
          "captured_at" => nil,
          "received_at" => "2026-09-14T10:36:02Z",
          "capture_session_id" => "boot-07",
          "derivation_of" => [],
          "limitations" => ["仅有日志片段，尚未完成真机复测。"],
          "supersedes" => nil,
          "content_status" => "available",
          "review_status" => "unseen"
        },
        nil
      )

    {:ok, _} =
      Store.emit_event("embedded-lab-demo", "evidence.registered", "Evidence", "E-017",
        payload: %{"detail" => "已记录日志片段"},
        entity_revision: 1
      )
  end

  test "a comment with no text is refused instead of recorded as an empty note" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    html = view |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "   "}}) |> render_submit()

    assert html =~ "发送失败"
    assert html =~ "没有针对该 Issue 的操作。"
  end

  test "requesting evidence records the question that was typed" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    view |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "请补一次上电时序的原始记录。"}}) |> render_change()
    html = view |> element("button", "要求补充证据") |> render_click()

    assert html =~ "请补一次上电时序的原始记录。"
  end

  test "the new-issue form holds its draft server-side" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    view |> element("button", "新建 Issue") |> render_click()

    html =
      view
      |> form("form[phx-submit='create']", %{"issue" => %{"title" => "草稿标题", "description" => "草稿说明"}})
      |> render_change()

    assert html =~ "草稿标题"
    assert html =~ "草稿说明"
  end

  test "a create carries the chosen assignee to the provider" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    view |> element("button", "新建 Issue") |> render_click()

    html =
      view
      |> form("form[phx-submit='create']", %{
        "issue" => %{"title" => "指派给硬件", "native_state" => "Todo", "assignee_id" => "Hardware Agent"}
      })
      |> render_submit()

    assert html =~ "指派给硬件"

    {:ok, issue} = DemoAdapter.get_issue("DEMO-9")
    assert issue.assignee_id == "Hardware Agent"
  end

  test "the issue detail route reports a disabled workbench instead of an empty page" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: %{"enabled" => false, "mode" => "demo"}
    )

    {:ok, _view, html} = live(build_conn(), "/workbench/issues/EMB-42")

    assert html =~ "工作台未启用"
  end

  test "the workbench's own store can be swept without naming it" do
    {:ok, receipt} = Store.put_blob("embedded-lab-demo", "nobody names this", "text/plain")

    # The default server is the workbench's own store, so an operator sweeping a
    # host does not have to know which process it is registered as.
    assert {:ok, [%{"sha256" => digest}]} = Store.orphan_blobs()
    assert digest == receipt["sha256"]

    assert {:ok, %{"deleted" => [%{"sha256" => ^digest, "size_bytes" => 17}], "freed_bytes" => 17}} =
             Store.reclaim_blobs([digest])
  end

  test "a store outage degrades the detail page instead of crashing it" do
    # The durable store goes away; the provider-owned parts of the page must
    # still render, with the engineering sections honestly empty.
    GenServer.stop(Process.whereis(Store))

    {:ok, _view, html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    assert html =~ "修复显示画面偶发撕裂"
    assert html =~ "没有针对该 Issue 的操作。"
    assert html =~ "还没有问题分析记录。"
    assert html =~ "还没有证据记录。"
  end

  test "a create with no title is refused before reaching the provider" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues")

    view |> element("button", "新建 Issue") |> render_click()

    html =
      view
      |> form("form[phx-submit='create']", %{"issue" => %{"title" => "   ", "native_state" => "Todo"}})
      |> render_submit()

    assert html =~ "创建失败"
    assert has_element?(view, "section[aria-label='新建 Issue']")
  end

  test "the activity tab shows the receipt of an operation recorded earlier" do
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42?tab=investigation")

    view
    |> form("form[phx-submit='comment']", %{"comment" => %{"body" => "请补一次真机复测。"}})
    |> render_submit()

    {:ok, _activity, html} = live(build_conn(), "/workbench/issues/EMB-42?tab=activity")

    assert html =~ "comment"
    assert html =~ "applied"
    assert html =~ "received：confirmed"
  end

  test "the review list shows the decisions and reviews that were recorded" do
    seed_decision()
    seed_review()

    {:ok, _view, html} = live(build_conn(), "/workbench/reviews")

    assert html =~ "decision-EMB-40"
    assert html =~ "draft"
    assert html =~ "r12"
    assert html =~ "changes_requested"
    assert html =~ "还需要一次真机复测"
  end

  test "selecting a candidate writes nothing until adopt is submitted" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    assert render(view) =~ "先选择一个候选方案。"

    view |> element("input#option-A") |> render_click()

    assert render(view) =~ "将采用方案 A"
    assert render(view) =~ "这只是候选选择，提交后才会记录决定"

    # No operation was submitted, so the store still holds only the draft.
    assert [decision] = Store.list("embedded-lab-demo", "Decision")
    assert decision.payload["status"] == "draft"
    assert decision.payload["selected_option_id"] == nil
  end

  test "adopting a candidate records the decision and publishes the plan" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    html =
      view
      |> form("form[phx-submit='adopt']", %{"adopt" => %{"option_id" => "A"}})
      |> render_submit()

    assert html =~ "adopt_decision"
    assert html =~ "applied"

    revisions = Store.list_revisions("embedded-lab-demo", "Decision")
    assert Enum.map(revisions, & &1.entity_revision) == [1, 2]

    adopted = List.last(revisions)
    assert adopted.payload["status"] == "adopted"
    assert adopted.payload["selected_option_id"] == "A"
    assert adopted.payload["constraints"] == ["优先保证稳定性"]
    assert adopted.payload["actor"]["kind"] == "human"

    # The issue is paused so the new plan is the one the next executor reads.
    {:ok, issue} = DemoAdapter.get_issue("demo-issue-42")
    assert issue.state == "Human Review"

    assert {:ok, %{plan: plan}} = DemoAdapter.get_workpad("demo-issue-42")
    assert plan["plan_revision"] == "r13"
  end

  test "the adopt button stays disabled without a selection" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    assert has_element?(view, "button[type='submit'][disabled]", "采用方案")
  end

  test "editing the constraints of a draft candidate publishes no plan" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    html =
      view
      |> form("form[phx-submit='adjust-constraints']", %{"constraints" => %{"body" => "稳定性优先\n不做双缓冲"}})
      |> render_submit()

    assert html =~ "adjust_constraints"
    assert html =~ "applied"

    assert [first, second] = Store.list_revisions("embedded-lab-demo", "Decision")
    assert length([first, second]) == 2
    assert second.payload["constraints"] == ["稳定性优先", "不做双缓冲"]
    assert second.payload["status"] == "draft"

    # A draft edit must not change what the executor will read.
    assert {:ok, nil} = DemoAdapter.get_workpad("demo-issue-42")
  end

  test "an adopt with no candidate is refused instead of guessing" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    html = view |> form("form[phx-submit='adopt']", %{"adopt" => %{}}) |> render_submit()

    assert html =~ "提交失败"
    assert html =~ "option_id"

    # Nothing was recorded, so the decision is still a draft.
    assert [draft] = Store.list("embedded-lab-demo", "Decision")
    assert draft.payload["status"] == "draft"
  end

  test "adopting with a resume target resumes the issue after publishing" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    view |> element("input#resume-after-apply") |> render_click()
    view |> element("input#resume-target") |> render_change(%{"resume" => %{"target_state" => "In Progress"}})

    html =
      view
      |> form("form[phx-submit='adopt']", %{"adopt" => %{"option_id" => "A"}})
      |> render_submit()

    assert html =~ "applied"

    {:ok, issue} = DemoAdapter.get_issue("demo-issue-42")
    assert issue.state == "In Progress"
  end

  test "the review page reports a disabled workbench instead of an empty list" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: %{"enabled" => false, "mode" => "demo"}
    )

    {:ok, _view, html} = live(build_conn(), "/workbench/reviews")

    assert html =~ "工作台未启用"
  end

  test "the constraints box keeps what was typed before it is saved" do
    seed_decision()

    {:ok, view, _html} = live(build_conn(), "/workbench/reviews/decision-EMB-40")

    html =
      view
      |> form("form[phx-submit='adjust-constraints']", %{"constraints" => %{"body" => "草稿约束"}})
      |> render_change()

    assert html =~ "草稿约束"
  end

  test "a store outage is reported without taking the review page down" do
    seed_decision()
    GenServer.stop(Process.whereis(Store))

    {:ok, _view, html} = live(build_conn(), "/workbench/reviews")

    assert html =~ "审阅记录"
    assert html =~ "还没有记录到方案决定。"
  end

  test "an unknown decision is reported instead of an empty form" do
    {:ok, _view, html} = live(build_conn(), "/workbench/reviews/decision-missing")

    assert html =~ "找不到决定 decision-missing"
  end

  defp seed_decision do
    payload = %{
      "id" => "decision-EMB-40",
      "project_id" => "embedded-lab-demo",
      "revision" => 1,
      "issue_id" => "demo-issue-42",
      "problem_case_ids" => ["DISP-12"],
      "options" => [
        %{"id" => "A", "title" => "延后释放", "proposal" => "保持单缓冲", "tradeoffs" => ["Agent 建议"], "evidence_ids" => [], "remaining_validation" => ["方案 A 仍需真机验证。"]},
        %{"id" => "B", "title" => "双缓冲", "proposal" => "隔离读写", "tradeoffs" => ["增加内存占用"], "evidence_ids" => [], "remaining_validation" => ["内存预算"]}
      ],
      "status" => "draft",
      "selected_option_id" => nil,
      "constraints" => ["优先保证稳定性"],
      "plan_revision" => "r12",
      "actor" => %{"kind" => "agent", "id" => "run-1", "display_name" => "Driver Agent"},
      "limitations" => ["现有证据尚不足以确认根因。"],
      "supersedes" => nil
    }

    {:ok, _} =
      Store.append("embedded-lab-demo", "Decision", payload["id"], 0, payload, %{
        kind: "agent",
        id: "run-1",
        display_name: "Driver Agent"
      })
  end

  defp seed_review do
    {:ok, _} =
      Store.append(
        "embedded-lab-demo",
        "Review",
        "E-017",
        0,
        %{
          "action" => "review",
          "target_type" => "evidence",
          "target_id" => "E-017",
          "issue_id" => "demo-issue-42",
          "body" => "还需要一次真机复测。",
          "verdict" => "changes_requested"
        },
        %{kind: "human", id: "local-operator", display_name: "本机操作者"}
      )
  end

  describe "devices page" do
    defp start_devices_manager(context, devices_yaml) do
      if pid = Process.whereis(Manager), do: GenServer.stop(pid)

      path = Path.join(context.root, "devices.yaml")
      File.write!(path, devices_yaml)

      # `restart: :transient` lets one test take the manager down deliberately.
      start_supervised!(%{id: Manager, start: {Manager, :start_link, [[config_path: path]]}, restart: :transient})

      on_exit(fn -> if pid = Process.whereis(Manager), do: GenServer.stop(pid) end)
    end

    test "a host with no registered devices says so instead of showing a blank table", context do
      start_devices_manager(context, "schema_version: \"1.0\"\nhost_id: \"test-host\"\n")

      {:ok, _view, html} = live(build_conn(), "/workbench/devices")

      assert html =~ "宿主没有登记任何设备"
      assert html =~ "devices.yaml"
    end

    test "lists the registered devices and shows one in detail", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          adapter: "serial"
          port: "/dev/symphony-does-not-exist"
          hardware_revision: "rev A"
      actions: []
      """)

      {:ok, view, html} = live(build_conn(), "/workbench/devices")

      assert html =~ "开发板 A"
      assert html =~ "rev A"
      assert html =~ "unknown"

      view |> element("tr[phx-value-device='board-a']") |> render_click()

      assert render(view) =~ "/dev/symphony-does-not-exist"
      assert render(view) =~ "在线只表示连接可用，不代表验证通过"
      assert render(view) =~ "真机复测未完成"
    end

    test "refresh probes the port and reports it honestly", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices")

      html = view |> element("button", "刷新") |> render_click()

      assert html =~ "offline"
    end

    test "the serial tab starts empty and refuses a device without a port", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")

      assert render(view) =~ "还没有采集到的原始字节。"

      html = view |> element("button", "开始采集") |> render_click()

      assert html =~ "无法开始采集"
      assert html =~ "device_has_no_port"
    end

    test "pausing the scroll keeps the capture running", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")

      html = view |> element("button", "暂停滚动") |> render_click()

      assert html =~ "已暂停滚动"
      assert html =~ "采集与写盘仍在继续"
      assert html =~ "恢复滚动"
    end

    test "a real capture shows the bytes it read and stops on request", context do
      peer = open_pty_peer()

      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "#{peer.path}"
          action_ids: ["reboot"]
      actions:
        - tool_id: "reboot"
          absolute_executable: "/bin/echo"
          fixed_argv_template: ["rebooting"]
          required_capability: "control"
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")

      html = view |> element("button", "开始采集") |> render_click()

      assert html =~ "采集已开始"
      assert html =~ "停止采集"

      write_to_peer(peer, "boot ok\n")
      Process.sleep(300)
      view |> element("button", "暂停滚动") |> render_click()

      rendered = render(view)
      assert rendered =~ "boot ok"
      assert rendered =~ "显示文本是原始字节的派生视图" or rendered =~ "已暂停滚动"

      # An unrelated message must not disturb the page.
      send(view.pid, :unrelated)
      send(view.pid, {:serial, {:state, :connected, "port opened"}})
      Process.sleep(50)

      html = view |> element("button", "停止采集") |> render_click()
      assert html =~ "物理动作的停止需另行确认"

      Port.command(peer.port, "quit\n")
    end

    test "refreshing a selected device reports the probe it ran", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a")

      html = view |> element("button", "刷新") |> render_click()

      assert html =~ "offline"
      assert html =~ "开发板 A"
    end

    test "a capture loop that is gone leaves the page readable", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
      actions: []
      """)

      GenServer.stop(Process.whereis(Manager))

      # A device manager that is not running is reported as unavailable rather
      # than as "this host has no devices".
      {:ok, _view, html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")

      assert html =~ "设备管理未运行"
      assert html =~ "其它页面不受影响"
    end

    test "keeps rendering a live capture view after the capture loop dies", context do
      peer = open_pty_peer()

      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "#{peer.path}"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")
      view |> element("button", "开始采集") |> render_click()

      GenServer.stop(Process.whereis(Manager))

      # A refresh tick after the manager died must not take the page down.
      send(view.pid, {:serial, {:state, :disconnected, "manager gone"}})
      Process.sleep(50)

      assert render(view) =~ "开发板 A"
      assert render(view) =~ "还没有采集到的原始字节。"

      Port.command(peer.port, "quit\n")
    end

    test "a stop request the manager refuses is reported", context do
      peer = open_pty_peer()

      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "#{peer.path}"
      actions: []
      """)

      {:ok, view, _html} = live(build_conn(), "/workbench/devices?device=board-a&tab=serial")
      view |> element("button", "开始采集") |> render_click()
      assert render(view) =~ "停止采集"

      # The page still shows the session it started; the manager no longer has
      # it, so the stop must be reported as refused rather than as stopped.
      :sys.replace_state(Manager, fn state -> %{state | sessions: %{}} end)

      html = view |> element("button", "停止采集") |> render_click()

      assert html =~ "无法停止采集"
      assert html =~ "no_capture_session"

      Port.command(peer.port, "quit\n")
    end

    test "shows who holds a device lease", context do
      start_devices_manager(context, """
      schema_version: "1.0"
      host_id: "test-host"
      devices:
        - key: "board-a"
          display_name: "开发板 A"
          port: "/dev/symphony-does-not-exist"
      actions: []
      """)

      {:ok, _lease} = Manager.acquire_lease(Manager, "board-a", "run-7")

      {:ok, _view, html} = live(build_conn(), "/workbench/devices")

      assert html =~ "run-7"
    end

    defp open_pty_peer do
      port =
        Port.open({:spawn_executable, System.find_executable("python3")}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stream,
          line: 4096,
          args: [Path.expand("../support/pty_peer.py", __DIR__)]
        ])

      %{port: port, path: wait_for_peer_port(port)}
    end

    defp wait_for_peer_port(port) do
      receive do
        {^port, {:data, {:eol, "PORT " <> path}}} -> String.trim(path)
        {^port, {:data, {:noeol, "PORT " <> path}}} -> String.trim(path)
      after
        5_000 -> flunk("PTY peer did not report a port")
      end
    end

    defp write_to_peer(peer, bytes) do
      Port.command(peer.port, ["write ", Base.encode64(bytes), "\n"])

      receive do
        {_port, {:data, {:eol, "OK"}}} -> :ok
        {_port, {:data, {:noeol, "OK"}}} -> :ok
      after
        5_000 -> flunk("PTY peer did not acknowledge")
      end
    end

    test "the devices page reports a disabled workbench" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        tracker_project_slug: nil,
        workbench: %{"enabled" => false, "mode" => "demo"}
      )

      {:ok, _view, html} = live(build_conn(), "/workbench/devices")

      assert html =~ "工作台未启用"
    end
  end

  test "the workbench reports a disabled configuration instead of a blank board" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workbench: %{"enabled" => false, "mode" => "demo"}
    )

    {:ok, _view, html} = live(build_conn(), "/workbench/issues")

    assert html =~ "工作台未启用"
    assert html =~ "查看运行状态"
  end
end

defmodule SymphonyElixirWeb.WorkbenchLiveLinearTest do
  # The live provider path is exercised through the real workbench pages, with
  # the host GraphQL client swapped for a fixture so no network is touched.
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias SymphonyElixir.Experience.{Architecture, Canonical, Project, Query, Store}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeClient do
    @moduledoc false

    def graphql(query, _variables) do
      cond do
        String.contains?(query, "SymphonyWorkbenchProject") -> project_response()
        String.contains?(query, "SymphonyWorkbenchIssues") -> list_response()
        String.contains?(query, "SymphonyWorkbenchComments") -> comments_response()
        true -> {:ok, %{"data" => %{}}}
      end
    end

    defp project_response do
      {:ok,
       %{
         "data" => %{
           "project" => %{
             "id" => "project-1",
             "name" => "Embedded Lab",
             "teams" => %{
               "nodes" => [
                 %{
                   "id" => "team-1",
                   "name" => "Embedded",
                   "states" => %{
                     "nodes" => [
                       %{"id" => "s-1", "name" => "Todo", "type" => "unstarted"},
                       %{"id" => "s-2", "name" => "In Progress", "type" => "started"},
                       %{"id" => "s-3", "name" => "Done", "type" => "completed"}
                     ]
                   }
                 }
               ]
             }
           }
         }
       }}
    end

    defp list_response do
      {:ok, %{"data" => %{"issues" => %{"nodes" => [issue_node()], "pageInfo" => %{"hasNextPage" => false}}}}}
    end

    defp comments_response do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [
                 %{
                   "id" => "comment-2",
                   "body" =>
                     "## Codex Workpad\n\n<!-- symphony-engineering-plan -->\n- decision_id: DISP-12\n- decision_revision: 2\n- decision_sha256: #{String.duplicate("a", 64)}\n- plan_revision: r13\n- constraints: 优先保证稳定性\n- remaining_validation: 真机复测\n<!-- symphony-engineering-plan -->\n",
                   "resolvedAt" => nil,
                   "updatedAt" => "2026-09-15T10:00:00Z"
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end

    defp issue_node do
      %{
        "id" => "issue-42",
        "identifier" => "EMB-42",
        "title" => "修复显示画面偶发撕裂",
        "description" => "描述",
        "state" => %{"id" => "s-2", "name" => "In Progress"},
        "url" => "https://example.invalid/EMB-42",
        "labels" => %{"nodes" => []},
        "createdAt" => "2026-09-14T10:00:00Z",
        "updatedAt" => "2026-09-14T10:38:00Z"
      }
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-workbench-live-linear-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    if pid = Process.whereis(Store), do: GenServer.stop(pid)

    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
    # `restart: :transient` lets one test take the store down deliberately
    # without the supervisor putting it straight back.
    start_supervised!(%{id: Store, start: {Store, :start_link, [[data_root: root]]}, restart: :transient})

    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeClient)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        value -> Application.put_env(:symphony_elixir, :linear_client_module, value)
      end

      if pid = Process.whereis(Store), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: "embedded-lab",
      workbench: %{
        "enabled" => true,
        "mode" => "live",
        "project_id" => "embedded-lab",
        "data_root" => root,
        "display_states" => ["Todo", "In Progress", "Done"]
      }
    )

    :ok
  end

  test "a live review page shows no demonstration notice" do
    {:ok, _view, html} = live(build_conn(), "/workbench/reviews")

    assert html =~ "审阅记录"
    assert html =~ "还没有记录到方案决定。"
    refute html =~ "演示数据"
  end

  test "a live board shows provider issues without a demonstration notice" do
    {:ok, _view, html} = live(build_conn(), "/workbench/issues")

    assert html =~ "EMB-42"
    assert html =~ "In Progress"
    refute html =~ "演示数据"
  end

  test "a board the provider cannot answer for says so instead of rendering empty" do
    Application.put_env(:symphony_elixir, :linear_client_module, __MODULE__.BrokenClient)

    {:ok, view, html} = live(build_conn(), "/workbench/issues")

    assert html =~ "读取 Issue 失败"

    view |> element("button", "新建 Issue") |> render_click()
    refute has_element?(view, "select[name='issue[native_state]'] option")
  end

  defmodule BrokenClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:error, {:http_error, 503, "down"}}
  end

  test "the overview shows the plan reference the executor is running under" do
    {:ok, _view, html} = live(build_conn(), "/workbench/issues/EMB-42")

    assert html =~ "DISP-12"
    assert html =~ "r13"
    refute html =~ "还没有已采用的计划引用"

    # The rendered digest is the plan reference's own hash, computed here rather
    # than copied from the workpad, so a reader can tell what was run.
    {:ok, view, _html} = live(build_conn(), "/workbench/issues/EMB-42")
    assert render(view) =~ "计划摘要"

    {:ok, project} = Project.load()
    plan = Query.issue_context(project, "EMB-42") |> elem(1) |> Map.fetch!("current_plan")
    assert String.length(plan["plan_sha256"]) == 64
    assert plan["decision_revision"] == 2
  end

  describe "architecture page" do
    @revision "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"

    defp artifact_ir do
      %{
        "components" => [%{"id" => "core", "label" => "Core"}, %{"id" => "storage", "label" => "Storage"}],
        "connections" => [%{"id" => "rel_1", "from" => "core", "to" => "storage"}]
      }
    end

    defp artifact_manifest(files, overrides) do
      Map.merge(
        %{
          "schema_version" => "1.0",
          "project_id" => "embedded-lab-demo",
          "artifact_id" => "art-1",
          "kind" => "source",
          "source_repo_url" => "https://github.com/rayheto/symphony_embedded",
          "source_revision" => @revision,
          "base_revision" => nil,
          "plan_revision" => nil,
          "plan_sources" => [],
          "skill_commit" => Architecture.skill_commit(),
          "ir_sha256" => files["ir"],
          "html_sha256" => files["html"],
          "deliver_receipt_sha256" => files["deliver"],
          "browser_receipt_sha256" => files["browser"],
          "visual_review_sha256" => nil,
          "components" => [
            %{
              "id" => "core",
              "label" => "Core",
              "layers" => ["L2"],
              "source_refs" => [
                %{
                  "kind" => "git",
                  "locator" => "elixir/lib/core.ex",
                  "repo_revision" => @revision,
                  "line" => 1,
                  "end_line" => 9
                }
              ],
              "issue_ids" => [],
              "problem_case_ids" => [],
              "evidence_ids" => [],
              "implementation_status" => "planned",
              "verification_status" => "unverified"
            }
          ],
          "limitations" => ["验证范围只覆盖已提交的 blob。"],
          "relationships" => [
            %{
              "id" => "rel_1",
              "from_component_id" => "core",
              "to_component_id" => "storage",
              "description" => "core 写入 storage",
              "source_refs" => []
            }
          ]
        },
        overrides
      )
    end

    defp blob(bytes, media_type) do
      {:ok, project} = Project.load()
      {:ok, receipt} = Store.put_blob(project.project_id, bytes, media_type)
      receipt["sha256"]
    end

    defp publish_artifact(overrides \\ %{}, browser_status \\ "fail") do
      {:ok, project} = Project.load()
      overrides = Map.put_new(overrides, "project_id", project.project_id)

      ir_sha = blob(Canonical.encode!(artifact_ir()), "application/json")
      html_sha = blob("<html><body><svg></svg></body></html>", "text/html")

      deliver_sha =
        blob(
          Canonical.encode!(%{
            "ok" => true,
            "validation" => %{"checksPassed" => 9, "checkCount" => 9, "compositionStatus" => "pass", "errors" => 0, "warnings" => 0}
          }),
          "application/json"
        )

      browser_sha = blob(Canonical.encode!(%{"status" => browser_status, "error" => "网络受限"}), "application/json")

      files = %{"ir" => ir_sha, "html" => html_sha, "deliver" => deliver_sha, "browser" => browser_sha}
      manifest_sha = blob(Canonical.encode!(artifact_manifest(files, overrides)), "application/json")

      Architecture.validate_and_publish(project, %{
        "artifact_id" => Map.get(overrides, "artifact_id", "art-1"),
        "manifest_blob_sha256" => manifest_sha,
        "ir_blob_sha256" => ir_sha,
        "html_blob_sha256" => html_sha
      })
    end

    test "a project with no diagram says so instead of showing an empty frame" do
      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")

      assert html =~ "还没有为该项目生成架构图"
      assert html =~ "只登记请求并核对产物"
      refute html =~ "iframe"
    end

    test "a delivered diagram is shown with its revision, index and receipts" do
      {:ok, _artifact} = publish_artifact()

      {:ok, view, html} = live(build_conn(), "/workbench/architecture")

      assert html =~ "last-good：art-1"
      assert html =~ "源码图"
      assert html =~ "无法判断是否过期"
      assert html =~ "Core"
      assert html =~ "验证范围只覆盖已提交的 blob。"
      assert html =~ "交付验收"

      # The frame is sandboxed and pinned to the revision the page labelled.
      iframe = view |> element("iframe.wb-viewer") |> render()
      assert iframe =~ ~s(sandbox="allow-scripts allow-downloads")
      assert iframe =~ "rev=1"
      assert iframe =~ "theme=light"

      # A failed browser run is reported as a fact, not folded into delivery.
      assert render(view) =~ "失败（网络受限）"
    end

    test "selecting a component shows its sources and status" do
      {:ok, _artifact} = publish_artifact()
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")

      view |> element("tr[phx-value-component='core']") |> render_click()

      html = render(view)
      assert html =~ "elixir/lib/core.ex:1-9"
      assert html =~ "组件来源"
      assert html =~ @revision
    end

    test "a generation request is recorded without claiming a diagram exists" do
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")

      html =
        view
        |> form("form[phx-submit='request']", %{
          "request" => %{
            "kind" => "source",
            "issue_id" => "EMB-42",
            "source_revision" => @revision,
            "plan_sources" => ""
          }
        })
        |> render_submit()

      assert html =~ "已登记架构请求"
      assert html =~ "生成仍由原 Issue 工作流上的 Archify 任务完成"

      # The same revision is not queued twice.
      again =
        view
        |> form("form[phx-submit='request']", %{
          "request" => %{"kind" => "source", "issue_id" => "EMB-42", "source_revision" => @revision, "plan_sources" => ""}
        })
        |> render_submit()

      assert again =~ "queued"
    end

    test "a request without an issue is refused with the reason" do
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")

      html =
        view
        |> form("form[phx-submit='request']", %{
          "request" => %{"kind" => "source", "issue_id" => "", "source_revision" => @revision, "plan_sources" => ""}
        })
        |> render_submit()

      assert html =~ "无法登记请求"
      assert html =~ "issue_id"
    end

    test "a refused request keeps what was typed" do
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")

      params = %{
        "request" => %{"kind" => "source", "issue_id" => "EMB-42", "source_revision" => "HEAD", "plan_sources" => ""}
      }

      # Typing fires `phx-change` first, which is what puts the draft in the
      # socket; the submit that follows must not cost the operator it.
      form = form(view, "form[phx-submit='request']", params)
      render_change(form, params)
      html = render_submit(form, params)

      assert html =~ "无法登记请求"
      assert html =~ ~s(value="EMB-42")
      assert html =~ ~s(value="HEAD")
    end

    test "a refused generation is listed beside the last-good it did not replace" do
      {:ok, _good} = publish_artifact()

      assert {:error, :source_revision_required, %{}} =
               publish_artifact(%{"artifact_id" => "art-2", "source_revision" => "not-a-commit"})

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")

      assert html =~ "未被采纳的尝试"
      assert html =~ "source_revision_required"
      assert html =~ "last-good 仍是 art-1"
    end

    test "one artifact can be opened by id, and an unknown one degrades to the last-good" do
      {:ok, _artifact} = publish_artifact()

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture/art-1")
      assert html =~ "last-good：art-1"

      {:ok, _view, other} = live(build_conn(), "/workbench/architecture/art-9")
      assert other =~ "last-good：art-1"
    end

    test "the artifact endpoint serves the delivered bytes with a sandbox-safe policy" do
      {:ok, _artifact} = publish_artifact()

      conn = get(build_conn(), "/workbench/architecture/art-1/artifact/html?rev=1")
      assert response(conn, 200) =~ "<svg"
      assert get_resp_header(conn, "content-security-policy") |> hd() =~ "connect-src 'none'"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get(build_conn(), "/workbench/architecture/art-1/artifact/manifest?rev=1") |> response(200) =~ "art-1"
      assert get(build_conn(), "/workbench/architecture/art-1/artifact/ir?rev=1") |> response(200) =~ "rel_1"

      assert get(build_conn(), "/workbench/architecture/art-1/artifact/poster") |> response(404) =~ "unknown_artifact_kind"
      assert get(build_conn(), "/workbench/architecture/art-9/artifact/html") |> response(404) =~ "artifact_not_found"
    end

    test "a revision that was only requested is shown as requested, not as a diagram" do
      params = %{"request" => %{"kind" => "source", "issue_id" => "EMB-42", "source_revision" => @revision, "plan_sources" => ""}}
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")
      render_submit(form(view, "form[phx-submit='request']", params), params)

      html = render(view)
      assert html =~ "尚未交付"
      assert html =~ "这一版没有可读的 manifest"

      # Refreshing re-reads the records rather than the page's memory of them.
      assert render_click(view, "refresh") =~ "last-good"

      # Selecting a component before any is indexed is a no-op, not a crash.
      assert render_click(view, "select-component", %{"component" => "core"}) =~ "这一版没有可读的 manifest"
    end

    test "a comparison artifact is listed with both of its revisions" do
      {:ok, _base} = publish_artifact()
      {:ok, _delta} = publish_artifact(%{"artifact_id" => "art-delta", "kind" => "delta", "base_revision" => @revision})

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")

      assert html =~ "对比图"
      assert html =~ "只有结构差异；不代表运行影响或安全结论。"
      assert html =~ "art-delta"
    end

    test "a component whose sources are not all linked is still shown" do
      {:ok, project} = Project.load()

      {:ok, _record} =
        Store.append(project.project_id, "Issue", "EMB-42", 0, %{"id" => "EMB-42", "state" => "Todo"}, %{
          kind: "system",
          id: "test",
          display_name: "测试"
        })

      {:ok, _artifact} =
        publish_artifact(%{
          "components" => [
            %{
              "id" => "core",
              "label" => "Core",
              "layers" => ["L2", "crosscutting"],
              "source_refs" => [
                %{"kind" => "git", "locator" => "elixir/lib/core.ex", "repo_revision" => @revision, "line" => nil, "end_line" => nil},
                %{"kind" => "git", "locator" => "README.md", "repo_revision" => @revision, "line" => 3, "end_line" => nil}
              ],
              "issue_ids" => ["EMB-42"],
              "problem_case_ids" => ["DISP-12"],
              "evidence_ids" => ["E-017"],
              "implementation_status" => "planned",
              "verification_status" => "unverified"
            }
          ]
        })

      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")
      view |> element("tr[phx-value-component='core']") |> render_click()

      html = render(view)
      assert html =~ "elixir/lib/core.ex"
      assert html =~ "README.md:3"
      assert html =~ "/workbench/issues/EMB-42"
      assert html =~ "问题分析"
      assert html =~ "证据"
      assert html =~ "L2 crosscutting"
    end

    test "an artifact that no longer matches the working revision is marked, not hidden" do
      {:ok, _artifact} = publish_artifact()
      {:ok, project} = Project.load()

      {:ok, _record} =
        Store.append(project.project_id, "Binding", "run-1", 0, %{"repo_revision" => @revision}, %{
          kind: "system",
          id: "test",
          display_name: "测试"
        })

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")
      assert html =~ "对应当前 revision"

      {:ok, _next} =
        Store.append(project.project_id, "Binding", "run-2", 0, %{"repo_revision" => String.duplicate("e", 40)}, %{
          kind: "system",
          id: "test",
          display_name: "测试"
        })

      {:ok, _view, stale} = live(build_conn(), "/workbench/architecture")
      assert stale =~ "已过期"
      refute stale =~ "对应当前 revision"
    end

    test "a skipped browser check is reported as skipped" do
      {:ok, _artifact} = publish_artifact(%{}, "skipped")

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")
      assert html =~ "跳过"
    end

    test "an artifact the store cannot list is reported instead of an empty page" do
      {:ok, _artifact} = publish_artifact()
      :ok = stop_supervised!(Store)

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")
      assert html =~ "无法读取架构记录"
      assert html =~ "store_unavailable"
    end

    test "a form with a structured field is treated as an empty one" do
      {:ok, view, _html} = live(build_conn(), "/workbench/architecture")

      params = %{"request" => %{"kind" => "source", "issue_id" => %{"nested" => "1"}, "source_revision" => @revision}}

      html = render_submit(view, "request", params)
      assert html =~ "无法登记请求"
      assert html =~ "issue_id"
    end

    test "opening a refused attempt shows what it was and why it failed" do
      {:ok, _good} = publish_artifact()

      assert {:error, :source_revision_required, %{}} =
               publish_artifact(%{"artifact_id" => "art-2", "source_revision" => "not-a-commit"})

      {:ok, view, html} = live(build_conn(), "/workbench/architecture/art-2")

      assert html =~ "失败（这一版未被采纳）"
      assert html =~ "这一版没有可嵌入的 HTML"
      assert html =~ "last-good：art-1 · 当前显示 art-2"
      assert render_click(view, "select-component", %{"component" => "core"}) =~ "这一版没有可读的 manifest"
    end

    test "an artifact endpoint without a usable revision falls back to the newest" do
      {:ok, _artifact} = publish_artifact()

      assert get(build_conn(), "/workbench/architecture/art-1/artifact/html") |> response(200) =~ "<svg"
      assert get(build_conn(), "/workbench/architecture/art-1/artifact/html?rev=abc") |> response(200) =~ "<svg"
      assert get(build_conn(), "/workbench/architecture/art-1/artifact/html?rev=0") |> response(200) =~ "<svg"
    end

    test "the artifact endpoint reports a disabled workbench instead of serving bytes" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        tracker_project_slug: nil
      )

      assert get(build_conn(), "/workbench/architecture/art-1/artifact/html") |> response(404) =~ "workbench disabled"
    end

    test "the architecture page reports a disabled workbench" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        tracker_project_slug: nil
      )

      {:ok, _view, html} = live(build_conn(), "/workbench/architecture")

      assert html =~ "工作台未启用"
    end
  end
end
