defmodule SymphonyElixirWeb.WorkbenchComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SymphonyElixir.Experience.IssueView
  alias SymphonyElixirWeb.WorkbenchComponents

  defp issue(attrs) do
    Map.merge(
      %{
        "identifier" => "EMB-42",
        "title" => "修复显示画面偶发撕裂",
        "labels" => ["调查中"],
        "assignee" => "Driver Agent",
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      attrs
    )
  end

  test "an applied receipt needs no warning" do
    assert WorkbenchComponents.receipt_warning(nil) == nil
    assert WorkbenchComponents.receipt_warning(%{"status" => "applied", "id" => "op-1"}) == nil
    assert WorkbenchComponents.receipt_warning(%{"status" => "received", "id" => "op-1"}) == nil
  end

  test "an unconfirmed outcome forbids a blind retry" do
    warning = WorkbenchComponents.receipt_warning(%{"status" => "outcome_unknown", "id" => "op-1"})

    assert warning =~ "op-1"
    assert warning =~ "不要直接重发"
  end

  test "a confirmed failure says it is safe to correct and retry" do
    warning = WorkbenchComponents.receipt_warning(%{"status" => "failed", "id" => "op-2", "error_code" => "unknown_state"})

    assert warning =~ "unknown_state"
    assert warning =~ "可修正后重试"

    without_code = WorkbenchComponents.receipt_warning(%{"status" => "conflict", "id" => "op-3", "error_code" => nil})
    assert without_code =~ "未记录原因"
  end

  test "only an applied receipt counts as applied" do
    assert WorkbenchComponents.applied?(%{"status" => "applied"})
    refute WorkbenchComponents.applied?(%{"status" => "failed"})
    refute WorkbenchComponents.applied?(nil)
  end

  test "reads a capability only when the provider offers it right now" do
    view = %IssueView{
      id: "issue-1",
      identifier: "EMB-42",
      native_state: "Todo",
      display_column: "待办",
      capabilities: [
        %{name: "read", available: true, reason: nil},
        %{name: "pause", available: false, reason: "not supported"}
      ]
    }

    assert WorkbenchComponents.capability?(view, "read")
    refute WorkbenchComponents.capability?(view, "pause")
    refute WorkbenchComponents.capability?(view, "workpad")
  end

  test "renders a relative time and never invents one" do
    now = DateTime.utc_now()

    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(now)) == "刚刚"
    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(DateTime.add(now, -90, :second))) == "1 分钟前"
    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(DateTime.add(now, -7_200, :second))) == "2 小时前"
    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(DateTime.add(now, -172_800, :second))) == "2 天前"
    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(DateTime.add(now, -60, :second))) == "1 分钟前"

    # A provider clock ahead of the host must not read as "in the future".
    assert WorkbenchComponents.relative_time(DateTime.to_iso8601(DateTime.add(now, 120, :second))) == "刚刚"
    assert WorkbenchComponents.relative_time("not-a-time") == "—"
    assert WorkbenchComponents.relative_time(nil) == "—"
    assert WorkbenchComponents.relative_time(1234) == "—"
  end

  test "the navigation keeps every product destination" do
    assert WorkbenchComponents.nav_links() == [
             {"/workbench/issues", "Issues"},
             {"/workbench/architecture", "项目架构"},
             {"/workbench/devices", "设备"},
             {"/workbench/reviews", "审阅记录"}
           ]
  end

  test "renders the shell with the account entry, notice and error slots" do
    html =
      render_component(&WorkbenchComponents.shell/1, %{
        active: "/workbench/issues",
        project_id: "embedded-lab",
        notice: "演示数据，不代表真实设备、实验或执行回执。",
        error: "创建失败：unknown_state",
        inner_block: [%{inner_block: fn _assigns, _opts -> "body" end}]
      })

    assert html =~ "查看运行状态"
    assert html =~ "wb-avatar"
    assert html =~ "embedded-lab"
    assert html =~ "演示数据"
    assert html =~ "创建失败"
    assert html =~ "aria-current=\"page\""
  end

  test "renders a column with its count and cards" do
    html =
      render_component(&WorkbenchComponents.column/1, %{
        column: "待办",
        issues: [issue(%{})],
        total: 3
      })

    assert html =~ "待办"
    assert html =~ ">3<"
    assert html =~ "EMB-42"
  end

  test "renders a state badge with text alongside the colour" do
    html = render_component(&WorkbenchComponents.state_badge/1, %{column: "已完成"})

    assert html =~ "已完成"
    assert html =~ "wb-dot-filled"
  end

  test "an unmapped column still renders with the neutral marker" do
    html = render_component(&WorkbenchComponents.state_badge/1, %{column: "Other"})

    assert html =~ "Other"
    assert html =~ "wb-col-todo"
  end
end
