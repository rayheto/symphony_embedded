defmodule SymphonyElixir.Linear.WorkbenchAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.WorkbenchAdapter

  @tracker %{project_slug: "embedded-lab", api_key: "token", endpoint: "https://api.linear.app/graphql"}

  defmodule FakeClient do
    @moduledoc false

    @handlers [
      {"SymphonyWorkbenchProject", :project_response},
      {"SymphonyWorkbenchMetadata", :metadata_response},
      {"SymphonyWorkbenchIssues", :list_response},
      {"SymphonyWorkbenchIssue(", :issue_response},
      {"SymphonyWorkbenchComments", :comments_response},
      {"SymphonyWorkbenchCreate", :create_response},
      {"SymphonyWorkbenchUpdate", :update_response},
      {"SymphonyWorkbenchCommentUpdate", :comment_update_response},
      {"SymphonyWorkbenchComment(", :comment_create_response}
    ]

    def graphql(query, variables) do
      case Enum.find(@handlers, fn {marker, _handler} -> String.contains?(query, marker) end) do
        nil -> {:error, :unknown_query}
        {_marker, handler} -> apply(__MODULE__, handler, [variables])
      end
    end

    def project_response(_variables) do
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
                   "states" => %{"nodes" => states()}
                 }
               ]
             }
           }
         }
       }}
    end

    def metadata_response(_variables) do
      {:ok,
       %{
         "data" => %{
           "viewer" => %{"organization" => %{"id" => "org-1", "name" => "Seeed"}},
           "teams" => %{"nodes" => []},
           "users" => %{"nodes" => [%{"id" => "user-1", "name" => "driver", "displayName" => "Driver Agent"}]},
           "issueLabels" => %{"nodes" => [%{"id" => "label-1", "name" => "调查中"}]}
         }
       }}
    end

    defp states do
      [
        %{"id" => "state-todo", "name" => "Todo", "type" => "unstarted", "position" => 1},
        %{"id" => "state-progress", "name" => "In Progress", "type" => "started", "position" => 2},
        %{"id" => "state-review", "name" => "Human Review", "type" => "backlog", "position" => 3},
        %{"id" => "state-done", "name" => "Done", "type" => "completed", "position" => 4}
      ]
    end

    def list_response(%{"after" => nil}) do
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [issue_node("issue-1", "EMB-42", "In Progress")],
             "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
           }
         }
       }}
    end

    def list_response(%{"after" => "cursor-2"}) do
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [issue_node("issue-2", "EMB-40", "Human Review")],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    def issue_response(%{"id" => "missing"}), do: {:ok, %{"data" => %{"issue" => nil}}}

    def issue_response(%{"id" => id}) do
      {:ok, %{"data" => %{"issue" => issue_node(id, "EMB-42", "In Progress")}}}
    end

    def comments_response(_variables) do
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [
                 %{"id" => "comment-1", "body" => "unrelated", "resolvedAt" => nil, "updatedAt" => "2026-09-15T10:00:00Z"},
                 %{
                   "id" => "comment-2",
                   "body" => "## Codex Workpad\n\nprogress\n",
                   "resolvedAt" => nil,
                   "updatedAt" => "2026-09-15T10:00:00Z"
                 },
                 %{"id" => "comment-3", "body" => "## Codex Workpad\nresolved", "resolvedAt" => "2026-09-15T09:00:00Z"}
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end

    def create_response(%{"input" => input}) do
      {:ok,
       %{
         "data" => %{
           "issueCreate" => %{
             "success" => true,
             "issue" => %{"id" => "issue-new", "identifier" => "EMB-99", "state" => %{"id" => input["stateId"], "name" => "Todo"}, "url" => "https://example.invalid/EMB-99"}
           }
         }
       }}
    end

    def update_response(%{"input" => %{"stateId" => state_id}}) when state_id == "state-done" do
      {:ok,
       %{
         "data" => %{
           "issueUpdate" => %{
             "success" => true,
             "issue" => %{"id" => "issue-1", "identifier" => "EMB-42", "state" => %{"id" => state_id, "name" => "Done"}, "updatedAt" => "2026-09-15T10:00:00Z"}
           }
         }
       }}
    end

    def comment_create_response(_variables) do
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-1", "url" => "https://example.invalid/c/1"}}}}}
    end

    def comment_update_response(%{"input" => %{"body" => body}}) do
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "comment-2", "updatedAt" => "2026-09-15T11:00:00Z", "body" => body}}}}}
    end

    defp issue_node(id, identifier, state) do
      %{
        "id" => id,
        "identifier" => identifier,
        "title" => "修复显示画面偶发撕裂",
        "description" => "描述",
        "state" => %{"id" => "state-progress", "name" => state},
        "url" => "https://example.invalid/#{identifier}",
        "assignee" => %{"id" => "user-1", "name" => "driver"},
        "labels" => %{"nodes" => [%{"id" => "label-1", "name" => "调查中"}]},
        "createdAt" => "2026-09-14T10:00:00Z",
        "updatedAt" => "2026-09-14T10:38:00Z"
      }
    end
  end

  defmodule TimeoutClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:error, :timeout}
  end

  defmodule ErrorBodyClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:ok, %{"errors" => [%{"message" => "nope"}]}}
  end

  defmodule UnauthorizedClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:error, {:http_error, 401, "unauthorized"}}
  end

  defmodule DownClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:error, {:http_error, 500, "boom"}}
  end

  defmodule UnknownFailureClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:error, :closed}
  end

  defmodule RejectingWriteClient do
    @moduledoc false

    def graphql(query, _variables) do
      cond do
        String.contains?(query, "SymphonyWorkbenchProject") -> FakeClient.graphql(query, %{})
        String.contains?(query, "SymphonyWorkbenchCreate") -> {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}}
        String.contains?(query, "SymphonyWorkbenchUpdate") -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
        String.contains?(query, "SymphonyWorkbenchComment(") -> {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
        true -> {:ok, %{"data" => %{}}}
      end
    end
  end

  defmodule WriteTimeoutClient do
    @moduledoc false

    def graphql(query, variables) do
      cond do
        String.contains?(query, "SymphonyWorkbenchCreate") -> {:error, :timeout}
        String.contains?(query, "SymphonyWorkbenchUpdate") -> {:error, :timeout}
        String.contains?(query, "SymphonyWorkbenchComment(") -> {:error, :timeout}
        String.contains?(query, "SymphonyWorkbenchCommentUpdate") -> {:error, :timeout}
        true -> FakeClient.graphql(query, variables)
      end
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge([tracker_settings: @tracker, client: FakeClient, display_states: ["Todo", "In Progress", "Human Review", "Done"]], extra)
  end

  test "declares only the capabilities Linear actually offers" do
    capabilities = WorkbenchAdapter.capabilities() |> Map.new(&{&1.name, &1})

    assert Map.keys(capabilities) |> Enum.sort() == SymphonyElixir.Experience.WorkbenchAdapter.known_capabilities() |> Enum.sort()
    assert Enum.all?(capabilities, fn {_name, capability} -> capability.available end)
    assert WorkbenchAdapter.secret_environment_names() == ["LINEAR_API_KEY"]
  end

  test "reads provider metadata with display columns" do
    assert {:ok, metadata} = WorkbenchAdapter.metadata(opts())

    assert metadata.provider == "linear"
    assert metadata.provider_project_id == "project-1"
    assert metadata.stale == false

    columns = Map.new(metadata.states, &{&1.name, &1.display_column})
    assert columns["Todo"] == "Todo"
    assert columns["In Progress"] == "In Progress"
    assert columns["Human Review"] == "Human Review"
    assert columns["Done"] == "Done"

    flags = Map.new(metadata.states, &{&1.name, {&1.active, &1.terminal}})
    assert flags["In Progress"] == {true, false}
    assert flags["Done"] == {false, true}
  end

  test "fetches form metadata for assignees and labels separately" do
    assert {:ok, metadata} = WorkbenchAdapter.form_metadata(opts())

    assert Enum.map(metadata.assignees, & &1.name) == ["Driver Agent"]
    assert Enum.map(metadata.labels, & &1.name) == ["调查中"]
    assert Enum.map(metadata.states, & &1.name) == ["Todo", "In Progress", "Human Review", "Done"]
  end

  test "validates that the provider exposes at least one workflow state" do
    assert :ok = WorkbenchAdapter.validate_metadata(opts())
    assert {:error, :missing_linear_project_slug, _} = WorkbenchAdapter.validate_metadata([])
  end

  test "follows pagination when listing issues" do
    assert {:ok, issues} = WorkbenchAdapter.list_issues(opts())

    assert Enum.map(issues, & &1.identifier) == ["EMB-42", "EMB-40"]
    assert Enum.all?(issues, &(&1.state in ["In Progress", "Human Review"]))
    assert List.first(issues).labels == ["调查中"]
    assert List.first(issues).updated_at == ~U[2026-09-14 10:38:00Z]
  end

  test "reads one issue and reports a miss" do
    assert {:ok, issue} = WorkbenchAdapter.get_issue("issue-1", opts())
    assert issue.identifier == "EMB-42"

    assert {:error, :not_found, %{issue_id: "missing"}} = WorkbenchAdapter.get_issue("missing", opts())
  end

  test "creates an issue through the provider and reports the confirmed state" do
    assert {:ok, created} =
             WorkbenchAdapter.create_issue(
               %{team_id: "team-1", project_id: "project-1", title: "t", native_state_id: "state-todo"},
               opts()
             )

    assert created.identifier == "EMB-99"
    assert created.native_state == "Todo"
  end

  test "never blindly resends a create whose result is unknown" do
    assert {:error, :outcome_unknown, _} =
             WorkbenchAdapter.create_issue(%{title: "t"}, opts(client: WriteTimeoutClient))
  end

  test "rejects a write the provider did not confirm" do
    assert {:error, :create_rejected, _} =
             WorkbenchAdapter.create_issue(%{title: "t"}, opts(client: RejectingWriteClient))

    assert {:error, :transition_rejected, _} =
             WorkbenchAdapter.transition("issue-1", "Human Review", opts(client: RejectingWriteClient))

    assert {:error, :comment_rejected, _} = WorkbenchAdapter.comment("issue-1", "body", opts(client: RejectingWriteClient))
  end

  test "reports unknown outcomes for writes that time out" do
    assert {:error, :outcome_unknown, _} = WorkbenchAdapter.transition("issue-1", "Done", opts(client: WriteTimeoutClient))
    assert {:error, :outcome_unknown, _} = WorkbenchAdapter.comment("issue-1", "b", opts(client: WriteTimeoutClient))

    assert {:error, :outcome_unknown, _} =
             WorkbenchAdapter.update_workpad_plan("issue-1", %{plan_revision: "r13"}, opts(client: WriteTimeoutClient))
  end

  test "transitions only to a state the provider actually exposes" do
    assert {:ok, %{native_state: "Done"}} = WorkbenchAdapter.transition("issue-1", "Done", opts())

    assert {:error, :unknown_state, %{state: "Nope"}} = WorkbenchAdapter.transition("issue-1", "Nope", opts())
  end

  test "surfaces provider errors instead of a silent success" do
    assert {:error, :provider_error, %{message: "nope"}} = WorkbenchAdapter.metadata(opts(client: ErrorBodyClient))
    assert {:error, :permission_denied, %{status: 401}} = WorkbenchAdapter.metadata(opts(client: UnauthorizedClient))
    assert {:error, :provider_unavailable, %{status: 500}} = WorkbenchAdapter.metadata(opts(client: DownClient))

    assert {:error, :provider_unavailable, %{reason: :closed}} =
             WorkbenchAdapter.metadata(opts(client: UnknownFailureClient))

    assert {:error, :timeout, %{}} = WorkbenchAdapter.metadata(opts(client: TimeoutClient))
  end

  test "posts a comment and returns the provider receipt" do
    assert {:ok, %{id: "c-1"}} = WorkbenchAdapter.comment("issue-1", "看这行日志", opts())
  end

  test "finds and reads back the single workpad comment" do
    assert {:ok, %{id: "comment-2", plan: nil}} = WorkbenchAdapter.get_workpad("issue-1", opts())
    assert {:ok, nil} = WorkbenchAdapter.get_workpad("issue-1", opts(client: __MODULE__.NoWorkpadClient))
  end

  test "writes a plan reference into the workpad and reads it back" do
    plan = %{
      decision_id: "dec-1",
      decision_revision: 3,
      decision_sha256: String.duplicate("a", 64),
      plan_revision: "r13",
      constraints: ["优先保证稳定性", "新增内存占用需说明"],
      remaining_validation: ["真机复测"]
    }

    assert {:ok, %{plan: ^plan}} = WorkbenchAdapter.update_workpad_plan("issue-1", plan, opts())

    rendered = WorkbenchAdapter.put_plan("## Codex Workpad\n\nbody\n", plan)
    assert rendered =~ "<!-- symphony-engineering-plan -->"
    assert rendered =~ "- plan_revision: r13"

    parsed = WorkbenchAdapter.parse_plan(rendered)
    assert parsed["decision_id"] == "dec-1"
    assert parsed["decision_revision"] == 3
    assert parsed["plan_revision"] == "r13"
    assert parsed["constraints"] == ["优先保证稳定性", "新增内存占用需说明"]
    assert parsed["remaining_validation"] == ["真机复测"]
  end

  test "replaces an existing plan section rather than appending a second one" do
    first = WorkbenchAdapter.put_plan("## Codex Workpad\n", %{plan_revision: "r12"})
    second = WorkbenchAdapter.put_plan(first, %{plan_revision: "r13"})

    assert length(String.split(second, "<!-- symphony-engineering-plan -->")) == 3
    assert WorkbenchAdapter.parse_plan(second)["plan_revision"] == "r13"
  end

  test "reports provider failures on writes instead of a silent success" do
    assert {:error, :provider_unavailable, %{status: 503}} =
             WorkbenchAdapter.create_issue(%{title: "t"}, opts(client: __MODULE__.ErrorClient))

    assert {:error, :provider_unavailable, %{status: 503}} =
             WorkbenchAdapter.comment("issue-1", "b", opts(client: __MODULE__.ErrorClient))

    assert {:error, :provider_unavailable, %{status: 503}} =
             WorkbenchAdapter.update_workpad_plan("issue-1", %{plan_revision: "r13"}, opts(client: __MODULE__.ErrorClient))
  end

  test "reports a rejected workpad update" do
    client_opts = opts(client: __MODULE__.RejectingWorkpadClient)

    assert {:error, :workpad_update_rejected, _} =
             WorkbenchAdapter.update_workpad_plan("issue-1", %{plan_revision: "r13"}, client_opts)
  end

  test "ignores a resolved workpad comment and an unreadable provider body" do
    assert {:ok, nil} = WorkbenchAdapter.get_workpad("issue-1", opts(client: __MODULE__.ResolvedWorkpadClient))
    assert {:error, :provider_error, %{body: "not a body"}} = WorkbenchAdapter.metadata(opts(client: __MODULE__.NonMapBodyClient))
  end

  test "reports an unparseable operation marker as unknown rather than guessed" do
    assert {:ok, %{status: "unknown", idempotency_key: nil}} =
             WorkbenchAdapter.find_operation_marker(
               "issue-1",
               opts(client: __MODULE__.UnknownMarkerClient, idempotency_key: "key-without-status")
             )
  end

  test "reports a provider error while creating or updating without pretending to succeed" do
    assert {:error, :provider_unavailable, %{status: 503}} =
             WorkbenchAdapter.create_issue(%{title: "t"}, opts(client: __MODULE__.CreateErrorClient))

    assert {:error, :provider_unavailable, %{status: 503}} =
             WorkbenchAdapter.update_workpad_plan("issue-1", %{plan_revision: "r13"}, opts(client: __MODULE__.WorkpadErrorClient))
  end

  test "follows comment pagination to find the workpad" do
    assert {:ok, %{id: "c-2"}} = WorkbenchAdapter.get_workpad("issue-1", opts(client: __MODULE__.PagingCommentsClient))
  end

  test "reads an empty plan section as empty rather than inventing defaults" do
    body = """
    <!-- symphony-engineering-plan -->
    - decision_id:
    - decision_revision:
    - decision_sha256:
    - plan_revision:
    - constraints:
    - remaining_validation:
    <!-- symphony-engineering-plan -->
    """

    plan = WorkbenchAdapter.parse_plan(body)

    assert plan["decision_id"] == nil
    assert plan["decision_revision"] == nil
    assert plan["constraints"] == []
    assert plan["remaining_validation"] == []
    assert WorkbenchAdapter.parse_plan("no plan here") == nil

    sparse =
      WorkbenchAdapter.parse_plan("<!-- symphony-engineering-plan -->\n- plan_revision: r13\n- decision_revision: not-a-number\n<!-- symphony-engineering-plan -->")

    assert sparse["plan_revision"] == "r13"
    assert sparse["decision_id"] == nil
    assert sparse["decision_revision"] == nil

    missing =
      WorkbenchAdapter.parse_plan("<!-- symphony-engineering-plan -->\n- plan_revision: r13\n<!-- symphony-engineering-plan -->")

    assert missing["decision_revision"] == nil
    assert missing["constraints"] == []
  end

  test "tolerates provider timestamps it cannot parse" do
    assert {:ok, issues} = WorkbenchAdapter.list_issues(opts(client: __MODULE__.BadTimestampClient))

    assert [%{created_at: nil, updated_at: nil}] = issues
  end

  defmodule BadTimestampClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchIssues") do
        {:ok,
         %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => "i-1",
                   "identifier" => "EMB-42",
                   "title" => "t",
                   "state" => %{"id" => "s", "name" => "Todo"},
                   "createdAt" => nil,
                   "updatedAt" => "not-a-timestamp"
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  test "reports a missing workpad instead of inventing one" do
    assert {:error, :workpad_missing, %{issue_id: "issue-1"}} =
             WorkbenchAdapter.update_workpad_plan("issue-1", %{plan_revision: "r13"}, opts(client: __MODULE__.NoWorkpadClient))
  end

  defmodule ErrorClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbench") do
        {:error, {:http_error, 503, "down"}}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule ResolvedWorkpadClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchComments") do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [
                   %{
                     "id" => "comment-3",
                     "body" => "## Codex Workpad\nresolved",
                     "resolvedAt" => "2026-09-15T09:00:00Z",
                     "updatedAt" => "2026-09-15T09:00:00Z"
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule UnknownMarkerClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchComments") do
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [
                   %{
                     "id" => "c-1",
                     "body" => "<!-- symphony-operation:key-without-status -->",
                     "resolvedAt" => nil,
                     "updatedAt" => "2026-09-15T10:00:00Z"
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule PagingCommentsClient do
    @moduledoc false

    def graphql(query, variables) do
      cond do
        String.contains?(query, "SymphonyWorkbenchComments") and variables["after"] == nil ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [%{"id" => "c-1", "body" => "first", "resolvedAt" => nil, "updatedAt" => "t"}],
                   "pageInfo" => %{"hasNextPage" => true, "endCursor" => "page-2"}
                 }
               }
             }
           }}

        String.contains?(query, "SymphonyWorkbenchComments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [%{"id" => "c-2", "body" => "## Codex Workpad\nlater", "resolvedAt" => nil, "updatedAt" => "t"}],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        true ->
          FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule NonMapBodyClient do
    @moduledoc false
    def graphql(_query, _variables), do: {:ok, "not a body"}
  end

  defmodule RejectingWorkpadClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchCommentUpdate") do
        {:ok, %{"data" => %{"commentUpdate" => %{"success" => false}}}}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule CreateErrorClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchCreate") do
        {:error, {:http_error, 503, "down"}}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule WorkpadErrorClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchCommentUpdate") do
        {:error, {:http_error, 503, "down"}}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end

  defmodule NoWorkpadClient do
    @moduledoc false

    def graphql(query, variables) do
      if String.contains?(query, "SymphonyWorkbenchComments") do
        {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
      else
        FakeClient.graphql(query, variables)
      end
    end
  end
end
