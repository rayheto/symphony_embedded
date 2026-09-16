defmodule SymphonyElixir.Experience.DefaultArityTest do
  # The production entry points are the arities without an options keyword, so
  # they must be exercised under the real registered names. This module owns the
  # globally registered demonstration state and the Linear client seam, which is
  # why it runs synchronously.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Experience.DemoAdapter
  alias SymphonyElixir.Experience.WorkbenchAdapter
  alias SymphonyElixir.Linear.WorkbenchAdapter, as: LinearWorkbenchAdapter

  defmodule FakeLinearClient do
    @moduledoc false

    def graphql(query, _variables) do
      cond do
        String.contains?(query, "SymphonyWorkbenchProject") ->
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
                           %{"id" => "s-1", "name" => "Todo", "type" => "unstarted", "position" => 1},
                           %{"id" => "s-2", "name" => "Cancelled", "type" => "canceled", "position" => 2},
                           %{"id" => "s-3", "name" => "Mystery", "type" => "weird", "position" => 3}
                         ]
                       }
                     }
                   ]
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyWorkbenchIssues") ->
          {:ok, %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}

        String.contains?(query, "SymphonyWorkbenchComments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "c-1", "body" => nil, "resolvedAt" => nil, "updatedAt" => "2026-09-15T10:00:00Z"},
                     %{
                       "id" => "c-2",
                       "body" => "<!-- symphony-operation:stable-key:applied -->",
                       "resolvedAt" => nil,
                       "updatedAt" => "2026-09-15T10:00:00Z"
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyWorkbenchComment(") ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-9", "url" => "u"}}}}}

        String.contains?(query, "SymphonyWorkbenchUpdate") ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => "i-1", "state" => %{"name" => "Todo"}}}}}}

        String.contains?(query, "SymphonyWorkbenchCreate") ->
          {:ok, %{"data" => %{"issueCreate" => %{"issue" => %{"id" => "i-9", "identifier" => "EMB-9"}}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:symphony_elixir, :linear_client_module)
        value -> Application.put_env(:symphony_elixir, :linear_client_module, value)
      end
    end)

    :ok
  end

  test "demo adapter entry points work without an options keyword" do
    if Process.whereis(DemoAdapter.State), do: GenServer.stop(DemoAdapter.State)
    start_supervised!({DemoAdapter, []})

    assert DemoAdapter.notice() =~ "演示数据"
    assert DemoAdapter.demo().project_id == "embedded-lab-demo"

    assert {:ok, metadata} = DemoAdapter.metadata()
    assert metadata.provider == "demo"

    assert {:ok, issues} = DemoAdapter.list_issues()
    assert length(issues) == 8

    assert {:ok, issue} = DemoAdapter.get_issue("EMB-42")
    assert issue.identifier == "EMB-42"

    assert {:ok, _created} = DemoAdapter.create_issue(%{title: "演示", native_state: "Todo"})
    assert {:ok, _} = DemoAdapter.transition("demo-issue-42", "Done")
    assert {:ok, _} = DemoAdapter.comment("demo-issue-42", "意见")

    assert {:error, :unsupported_capability, _} = DemoAdapter.update_workpad_plan("demo-issue-42", %{})
    assert :ok = DemoAdapter.reset()

    assert {:ok, issue} = DemoAdapter.get_issue("demo-issue-42")
    assert issue.state == "In Progress"
  end

  test "demo adapter starts under its own default name" do
    if Process.whereis(DemoAdapter.State), do: GenServer.stop(DemoAdapter.State)

    assert {:ok, pid} = DemoAdapter.start_link()
    assert Process.alive?(pid)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert DemoAdapter.demo().project_id == "embedded-lab-demo"
  end

  test "demo adapter tolerates malformed create input and unknown timestamps" do
    if Process.whereis(DemoAdapter.State), do: GenServer.stop(DemoAdapter.State)
    start_supervised!({DemoAdapter, []})

    assert {:ok, created} = DemoAdapter.create_issue(%{title: "无时间", created_at: nil, updated_at: nil})
    assert {:ok, issue} = DemoAdapter.get_issue(created.id)
    assert issue.created_at == nil
    assert issue.updated_at == nil

    assert {:ok, broken} = DemoAdapter.create_issue(%{title: "坏时间", created_at: "not-a-date"})
    assert {:ok, issue} = DemoAdapter.get_issue(broken.id)
    assert issue.created_at == nil

    assert {:ok, _} = DemoAdapter.create_issue("not a map")
  end

  test "the workbench adapter builds a capability with and without a reason" do
    assert %{name: "read", available: true, reason: nil} = WorkbenchAdapter.capability("read", true)
    assert %{name: "pause", available: false, reason: "no"} = WorkbenchAdapter.capability("pause", false, "no")
  end

  test "linear adapter entry points fail closed when no project is configured" do
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.metadata()
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.form_metadata()
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.validate_metadata()
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.list_issues()
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.get_issue("i-1")
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.create_issue(%{title: "t"})
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.transition("i-1", "Todo")
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.comment("i-1", "b")
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.find_operation_marker("i-1")
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.get_workpad("i-1")
    assert {:error, :missing_linear_project_slug, _} = LinearWorkbenchAdapter.update_workpad_plan("i-1", %{})
  end

  test "linear metadata classifies every provider state type" do
    settings = %{project_slug: "embedded-lab", api_key: "token", endpoint: "https://api.linear.app/graphql"}

    assert {:ok, metadata} = LinearWorkbenchAdapter.metadata(tracker_settings: settings)

    flags = Map.new(metadata.states, &{&1.name, {&1.active, &1.terminal}})
    assert flags["Todo"] == {true, false}
    assert flags["Cancelled"] == {false, true}
    assert flags["Mystery"] == {false, false}
  end

  test "linear reads the operation marker out of a workpad comment" do
    settings = %{project_slug: "embedded-lab", api_key: "token", endpoint: "https://api.linear.app/graphql"}

    assert {:ok, marker} =
             LinearWorkbenchAdapter.find_operation_marker("i-1",
               tracker_settings: settings,
               idempotency_key: "stable-key"
             )

    assert marker == %{comment_id: "c-2", idempotency_key: "stable-key", status: "applied"}

    assert {:ok, none} =
             LinearWorkbenchAdapter.find_operation_marker("i-1",
               tracker_settings: settings,
               idempotency_key: "other-key"
             )

    assert none == nil
  end

  test "linear creates an issue when the provider confirms without a success flag" do
    settings = %{project_slug: "embedded-lab", api_key: "token", endpoint: "https://api.linear.app/graphql"}

    assert {:ok, created} = LinearWorkbenchAdapter.create_issue(%{title: "t"}, tracker_settings: settings)
    assert created.identifier == "EMB-9"
  end

  test "linear reports a workspace with no workflow states instead of pretending" do
    settings = %{project_slug: "embedded-lab", api_key: "token", endpoint: "https://api.linear.app/graphql"}

    assert {:error, :no_provider_states, _} =
             LinearWorkbenchAdapter.validate_metadata(tracker_settings: settings, client: __MODULE__.EmptyStatesClient)
  end

  defmodule EmptyStatesClient do
    @moduledoc false

    def graphql(_query, _variables) do
      {:ok, %{"data" => %{"project" => %{"id" => "p", "teams" => %{"nodes" => []}}}}}
    end
  end
end
