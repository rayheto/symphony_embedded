defmodule SymphonyElixir.Experience.OperationsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.{DemoAdapter, Operations, Project, Store}

  @project_id "embedded-lab-demo"
  @actor %{kind: "human", id: "local-operator", display_name: "本机操作者"}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-ops-#{System.unique_integer([:positive])}")
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
        display_states: ["待办", "进行中", "待审阅", "已完成"],
        workspace_root: "/tmp/workspaces"
      },
      overrides
    )
  end

  defp opts(context), do: [demo_state: context.demo, actor: @actor]

  defp create_request(key, overrides \\ %{}) do
    %{
      action: "create_issue",
      idempotency_key: key,
      expected_revision: nil,
      payload:
        Map.merge(
          %{
            "title" => "看板新建",
            "description" => "说明",
            "native_state" => "Todo",
            "assignee_id" => nil,
            "label_ids" => []
          },
          overrides
        )
    }
  end

  describe "submit/4" do
    test "records the intent, applies it and returns the receipt", %{store: store} = context do
      assert {:ok, operation} = Operations.submit(project(context), @actor, create_request("key-create-0001"), opts(context))

      assert operation["status"] == "applied"
      assert operation["action"] == "create_issue"
      assert operation["result_entity_id"] =~ "demo-created-"
      assert operation["error_code"] == nil

      names = Enum.map(operation["steps"], & &1["name"])
      assert names == ["received", "applying", "applied"]
      assert Enum.all?(operation["steps"], &(&1["observed_at"] =~ "T"))

      # The receipt outlives the call that produced it.
      assert {:ok, reread} = Operations.get(project(context), operation["id"], opts(context))
      assert reread["id"] == operation["id"]
      assert reread["revision"] == operation["revision"]
      assert store == context.store
    end

    test "returns the recorded operation for an identical retry instead of writing twice", %{store: store} = context do
      assert {:ok, first} = Operations.submit(project(context), @actor, create_request("key-create-0002"), opts(context))

      assert {:ok, second} = Operations.submit(project(context), @actor, create_request("key-create-0002"), opts(context))

      assert first["id"] == second["id"]
      assert length(Operations.list(project(context), %{}, opts(context))) == 1
      assert store == context.store
    end

    test "refuses the same key used for a different request", %{store: store} = context do
      assert {:ok, _first} = Operations.submit(project(context), @actor, create_request("key-create-0003"), opts(context))

      assert {:error, :idempotency_conflict, %{existing_operation_id: _id}} =
               Operations.submit(
                 project(context),
                 @actor,
                 create_request("key-create-0003", %{"title" => "另一个请求"}),
                 opts(context)
               )

      assert store == context.store
    end

    test "refuses an unsupported action and a malformed key before writing anything", %{store: store} = context do
      request = %{action: "delete_everything", idempotency_key: "key-create-0004", expected_revision: nil, payload: %{}}

      assert {:error, :unsupported_action, %{supported: supported}} = Operations.submit(project(context), @actor, request, opts(context))
      assert "create_issue" in supported

      short = %{create_request("short") | idempotency_key: "short"}

      assert {:error, :invalid_idempotency_key, _} = Operations.submit(project(context), @actor, short, opts(context))
      assert Operations.list(project(context), %{}, opts(context)) == []
      assert store == context.store
    end

    test "records a failed provider write without pretending it succeeded", %{store: store} = context do
      failing = project(context, adapter: __MODULE__.FailingAdapter)

      assert {:ok, operation} = Operations.submit(failing, @actor, create_request("key-create-0005"), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "not_found"
      assert Enum.map(operation["steps"], & &1["name"]) == ["received", "applying", "not_found"]
      assert operation["result_entity_id"] == nil
      assert store == context.store
    end

    test "reports an unknown outcome for a create that timed out", %{store: store} = context do
      timing_out = project(context, adapter: __MODULE__.TimeoutAdapter)

      assert {:ok, operation} = Operations.submit(timing_out, @actor, create_request("key-create-0006"), opts(context))

      assert operation["status"] == "outcome_unknown"
      assert store == context.store
    end

    test "refuses a state the provider does not offer", %{store: store} = context do
      request = create_request("key-create-0007", %{"native_state" => "不存在"})

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "unknown_state"
      assert store == context.store
    end
  end

  describe "engineering notes" do
    test "records a review verdict as a durable note", %{store: store} = context do
      request = %{
        action: "review",
        idempotency_key: "key-review-0001",
        expected_revision: 1,
        payload: %{
          "issue_id" => "demo-issue-42",
          "target_type" => "evidence",
          "target_id" => "E-017",
          "verdict" => "changes_requested",
          "body" => "还需要一次真机复测。"
        }
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["status"] == "applied"

      assert [note] = Store.list(@project_id, "Review", server: store)
      assert note.payload["verdict"] == "changes_requested"
      assert note.payload["workpad_applied"] == false
    end

    test "records an evidence request without resuming anything", %{store: store} = context do
      request = %{
        action: "request_evidence",
        idempotency_key: "key-evidence-0001",
        expected_revision: nil,
        payload: %{
          "issue_id" => "demo-issue-42",
          "target_type" => "issue",
          "target_id" => "demo-issue-42",
          "question" => "请补一次上电时序的原始记录。"
        }
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["status"] == "applied"
      assert [note | _] = Store.list(@project_id, "Review", server: store)
      assert note.payload["body"] =~ "上电时序"
      assert note.payload["action"] == "request_evidence"
    end

    test "a repeated note request is recorded once", %{store: store} = context do
      request = %{
        action: "request_evidence",
        idempotency_key: "key-evidence-0002",
        expected_revision: nil,
        payload: %{"issue_id" => "demo-issue-42", "target_type" => "issue", "target_id" => "demo-issue-42", "question" => "再次请求"}
      }

      assert {:ok, first} = Operations.submit(project(context), @actor, request, opts(context))
      assert {:ok, second} = Operations.submit(project(context), @actor, request, opts(context))

      assert first["id"] == second["id"]
      assert [_note] = Store.list(@project_id, "Review", server: store)
    end
  end

  describe "list and reconcile" do
    test "lists operations newest first and filters by issue", %{store: store} = context do
      assert {:ok, _} = Operations.submit(project(context), @actor, create_request("key-create-0010"), opts(context))

      comment = %{
        action: "comment",
        idempotency_key: "key-comment-0010",
        expected_revision: nil,
        payload: %{"issue_id" => "demo-issue-42", "target_type" => "issue", "target_id" => "demo-issue-42", "body" => "看这行日志"}
      }

      assert {:ok, _} = Operations.submit(project(context), @actor, comment, opts(context))

      assert length(Operations.list(project(context), %{}, opts(context))) == 2
      assert [only] = Operations.list(project(context), %{issue_id: "demo-issue-42"}, opts(context))
      assert only["action"] == "comment"

      assert Operations.list(project(context), %{limit: 1}, opts(context)) |> length() == 1
      assert store == context.store
    end

    test "reports an unknown operation instead of inventing one", %{store: store} = context do
      assert {:error, :not_found, %{operation_id: "op-missing"}} = Operations.get(project(context), "op-missing", opts(context))
      assert store == context.store
    end

    test "rechecks an unresolved write by observing, never by resending", %{store: store} = context do
      assert {:ok, operation} = Operations.submit(project(context), @actor, comment_request("key-comment-0011"), opts(context))
      assert operation["status"] == "applied"

      # Only an unresolved receipt may be reconciled.
      assert {:error, :not_reconcilable, %{status: "applied"}} =
               Operations.reconcile(project(context), operation["id"], opts(context))

      assert store == context.store
    end

    test "observes the provider when a write is unresolved", %{store: store} = context do
      assert {:ok, operation} = Operations.submit(project(context), @actor, create_request("key-create-0012", %{"native_state" => "不存在"}), opts(context))
      assert operation["status"] == "failed"

      assert {:ok, reconciled} = Operations.reconcile(project(context), operation["id"], opts(context))
      assert reconciled["status"] in ["applied", "outcome_unknown"]
      assert Enum.any?(reconciled["steps"], &(&1["name"] == "observe"))
      assert store == context.store
    end

    test "reports a reconcile of an unknown operation", %{store: store} = context do
      assert {:error, :not_found, _} = Operations.reconcile(project(context), "op-missing", opts(context))
      assert store == context.store
    end
  end

  defp comment_request(key) do
    %{
      action: "comment",
      idempotency_key: key,
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "issue", "target_id" => "demo-issue-42", "body" => "意见"}
    }
  end

  test "transitions an issue through the provider and records the receipt", %{store: store} = context do
    request = %{
      action: "change_issue_state",
      idempotency_key: "key-transition-0001",
      expected_revision: 1,
      payload: %{"issue_id" => "demo-issue-42", "provider_version" => "v1", "target_state" => "Done"}
    }

    assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
    assert operation["status"] == "applied"
    assert operation["result_entity_id"] == "demo-issue-42"

    {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: context.demo)
    assert issue.state == "Done"
    assert store == context.store
  end

  test "refuses a blank note body before recording anything", %{store: store} = context do
    request = %{
      action: "review",
      idempotency_key: "key-review-0002",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "evidence", "target_id" => "E-017", "verdict" => "reviewed", "body" => "   "}
    }

    assert {:error, :invalid_payload, %{reason: "body must not be blank"}} = Operations.submit(project(context), @actor, request, opts(context))
    assert Operations.list(project(context), %{}, opts(context)) == []
    assert store == context.store
  end

  test "appends a further revision when the same target is noted again", %{store: store} = context do
    first = %{
      action: "review",
      idempotency_key: "key-review-0010",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "evidence", "target_id" => "E-017", "verdict" => "reviewed", "body" => "第一次意见"}
    }

    second = %{first | idempotency_key: "key-review-0011", payload: Map.put(first.payload, "body", "第二次意见")}

    assert {:ok, _} = Operations.submit(project(context), @actor, first, opts(context))
    assert {:ok, _} = Operations.submit(project(context), @actor, second, opts(context))

    revisions = Store.list_revisions(@project_id, "Review", server: store)
    assert Enum.map(revisions, & &1.entity_revision) == [1, 2]
    assert List.last(revisions).payload["body"] == "第二次意见"
  end

  test "reconciles an unresolved transition by reporting what the provider shows", %{store: store} = context do
    request = %{
      action: "change_issue_state",
      idempotency_key: "key-transition-0002",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "provider_version" => "v1", "target_state" => "Done"}
    }

    assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
    assert operation["status"] == "applied"

    # Re-open the receipt as unresolved, the way a crash mid-write would leave it.
    {:ok, %{payload: stored}} = Store.get(@project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        @project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    assert {:ok, reconciled} = Operations.reconcile(project(context), operation["id"], opts(context))

    # Observing the issue says where it is, not whether this call moved it, so
    # the receipt stays unresolved and reports the observation.
    assert reconciled["status"] == "outcome_unknown"
    assert Enum.any?(reconciled["steps"], &(&1["detail"] =~ "provider 当前状态"))
    assert store == context.store
  end

  test "settles a comment by finding its provider marker", %{store: store} = context do
    marked = project(context, adapter: __MODULE__.MarkedCommentAdapter)

    request = %{
      action: "comment",
      idempotency_key: "key-comment-0030",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "issue", "target_id" => "demo-issue-42", "body" => "意见"}
    }

    assert {:ok, operation} = Operations.submit(marked, @actor, request, opts(context))

    {:ok, %{payload: stored}} = Store.get(@project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        @project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    assert {:ok, reconciled} = Operations.reconcile(marked, operation["id"], opts(context))
    assert reconciled["status"] == "applied"
    assert Enum.any?(reconciled["steps"], &(&1["detail"] =~ "操作标记"))
  end

  test "keeps an unresolved note unresolved rather than guessing", %{store: store} = context do
    request = %{
      action: "review",
      idempotency_key: "key-review-0030",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "evidence", "target_id" => "E-017", "verdict" => "reviewed", "body" => "意见"}
    }

    assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
    {:ok, %{payload: stored}} = Store.get(@project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        @project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    assert {:ok, reconciled} = Operations.reconcile(project(context), operation["id"], opts(context))
    assert reconciled["status"] == "outcome_unknown"
    assert Enum.any?(reconciled["steps"], &(&1["detail"] =~ "人工确认"))
    assert store == context.store
  end

  test "reads and reconciles through the default options", %{store: store} = context do
    assert {:ok, operation} = Operations.submit(project(context), @actor, create_request("key-create-0020"), opts(context))

    # The default arity drops the caller options; the receipt still comes from
    # the project's own store.
    assert {:ok, reread} = Operations.get(project(context), operation["id"])
    assert reread["id"] == operation["id"]

    assert [_operation] = Operations.list(project(context))
    assert store == context.store
  end

  test "reports a store failure rather than an empty receipt", %{store: store, demo: demo} = context do
    broken = project(context, %{project_id: "../escape"})

    assert {:error, :invalid_project_id, _} = Operations.get(broken, "op-1", demo_state: demo)
    assert store == context.store
  end

  test "refuses a create with no title", %{store: store} = context do
    request = create_request("key-create-0040", %{"title" => "  "})

    assert {:error, :invalid_payload, %{reason: "title must not be blank"}} = Operations.submit(project(context), @actor, request, opts(context))
    assert Operations.list(project(context), %{}, opts(context)) == []
    assert store == context.store
  end

  test "maps provider failure codes onto receipt states", %{store: store} = context do
    unknown = project(context, adapter: __MODULE__.OutcomeUnknownAdapter)
    conflict = project(context, adapter: __MODULE__.ConflictAdapter)

    assert {:ok, first} = Operations.submit(unknown, @actor, create_request("key-create-0050"), opts(context))
    assert first["status"] == "outcome_unknown"

    assert {:ok, second} = Operations.submit(conflict, @actor, create_request("key-create-0051"), opts(context))
    assert second["status"] == "conflict"
    assert store == context.store
  end

  test "keeps a comment unresolved when the marker is not applied yet", %{store: store} = context do
    pending = project(context, adapter: __MODULE__.PendingMarkerAdapter)
    erroring = project(context, adapter: __MODULE__.BrokenMarkerAdapter)

    assert {:ok, note} = Operations.submit(pending, @actor, comment_request("key-comment-0060"), opts(context))
    assert {:ok, observed} = reconcile_unresolved(pending, note, store, opts(context))
    assert observed["status"] == "outcome_unknown"
    assert Enum.any?(observed["steps"], &(&1["detail"] =~ "未找到该操作标记"))

    assert {:ok, other} = Operations.submit(erroring, @actor, comment_request("key-comment-0061"), opts(context))
    assert {:ok, unreadable} = reconcile_unresolved(erroring, other, store, opts(context))
    assert unreadable["status"] == "outcome_unknown"
    assert Enum.any?(unreadable["steps"], &(&1["detail"] =~ "provider_down"))
  end

  test "reports a store failure while recording a note", %{store: store} = context do
    broken = project(context, %{project_id: "../escape"})

    request = %{
      action: "review",
      idempotency_key: "key-review-0070",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "evidence", "target_id" => "E-017", "verdict" => "reviewed", "body" => "意见"}
    }

    assert {:error, code, _details} = Operations.submit(broken, @actor, request, opts(context))
    assert code in [:invalid_project_id, :journal_unreadable]
    assert store == context.store
  end

  defp reconcile_unresolved(project, operation, store, opts) do
    {:ok, %{payload: stored}} = Store.get(project.project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        project.project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    Operations.reconcile(project, operation["id"], opts)
  end

  defmodule OutcomeUnknownAdapter do
    @moduledoc false
    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [%{id: "s-1", name: "Todo", display_column: "待办", active: true, terminal: false}],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, []}
    def get_issue(_id, _opts), do: {:error, :not_found, %{}}
    def create_issue(_attrs, _opts), do: {:error, :outcome_unknown, %{reason: "no answer"}}
  end

  defmodule ConflictAdapter do
    @moduledoc false
    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [%{id: "s-1", name: "Todo", display_column: "待办", active: true, terminal: false}],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, []}
    def get_issue(_id, _opts), do: {:error, :not_found, %{}}
    def create_issue(_attrs, _opts), do: {:error, :conflict, %{reason: "changed underneath"}}
  end

  defmodule PendingMarkerAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate transition(id, state, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter

    def find_operation_marker(_issue_id, _opts), do: {:ok, %{status: "pending"}}
  end

  defmodule BrokenMarkerAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate transition(id, state, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter

    def find_operation_marker(_issue_id, _opts), do: {:error, :provider_down, %{}}
  end

  test "refuses a note the durable store cannot hold, after recording the intent", %{store: store} = context do
    request = %{
      action: "review",
      idempotency_key: "key-review-0080",
      expected_revision: nil,
      payload: %{
        "issue_id" => "demo-issue-42",
        "target_type" => "evidence",
        "target_id" => "E-017",
        "verdict" => "reviewed",
        "body" => String.duplicate("a", 1_100_000)
      }
    }

    assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
    assert operation["status"] == "failed"
    assert operation["error_code"] == "payload_too_large"

    # The intent is still on record, so the operator can see what was refused.
    assert [_recorded] = Operations.list(project(context), %{}, opts(context))
    assert store == context.store
  end

  test "reconciles through the default options and reports an unreadable store", %{store: store} = context do
    note = %{
      action: "review",
      idempotency_key: "key-review-0090",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "target_type" => "evidence", "target_id" => "E-999", "verdict" => "reviewed", "body" => "意见"}
    }

    assert {:ok, operation} = Operations.submit(project(context), @actor, note, opts(context))
    {:ok, %{payload: stored}} = Store.get(@project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        @project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    # The default arity drops the caller options; the receipt still reconciles.
    assert {:ok, reconciled} = Operations.reconcile(project(context), operation["id"])
    assert reconciled["status"] == "outcome_unknown"

    broken = project(context, %{project_id: "../escape"})
    assert {:error, :invalid_project_id, _} = Operations.reconcile(broken, operation["id"], opts(context))
  end

  test "keeps an unreadable provider observation unresolved", %{store: store} = context do
    failing = project(context, adapter: __MODULE__.FailingTransitionAdapter)

    request = %{
      action: "change_issue_state",
      idempotency_key: "key-transition-0090",
      expected_revision: nil,
      payload: %{"issue_id" => "demo-issue-42", "provider_version" => "v1", "target_state" => "Done"}
    }

    assert {:ok, operation} = Operations.submit(failing, @actor, request, opts(context))
    {:ok, %{payload: stored}} = Store.get(@project_id, "Operation", operation["id"], server: store)

    {:ok, _} =
      Store.append(
        @project_id,
        "Operation",
        operation["id"],
        operation["revision"],
        stored |> Map.put("status", "outcome_unknown") |> Map.put("revision", operation["revision"] + 1),
        @actor,
        server: store
      )

    assert {:ok, reconciled} = Operations.reconcile(failing, operation["id"], opts(context))
    assert reconciled["status"] == "outcome_unknown"
    assert Enum.any?(reconciled["steps"], &(&1["detail"] =~ "not_found"))
  end

  defmodule FailingTransitionAdapter do
    @moduledoc false

    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [%{id: "s-1", name: "Done", display_column: "Done", active: false, terminal: true}],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, []}
    def get_issue(_id, _opts), do: {:error, :not_found, %{reason: "provider down"}}
    def create_issue(_attrs, _opts), do: {:error, :not_found, %{reason: "provider down"}}
    def transition(_id, _state, _opts), do: {:error, :not_found, %{reason: "provider down"}}
  end

  test "the documented action set matches what this build implements" do
    assert Operations.supported_actions() == ~w(create_issue change_issue_state comment request_evidence review)
  end

  defmodule MarkedCommentAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate transition(id, state, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter

    def find_operation_marker(_issue_id, _opts), do: {:ok, %{status: "applied", comment_id: "c-1"}}
  end

  defmodule FailingAdapter do
    @moduledoc false
    def metadata(_opts), do: {:error, :not_found, %{reason: "no provider"}}
    def list_issues(_opts), do: {:error, :not_found, %{}}
    def get_issue(_id, _opts), do: {:error, :not_found, %{}}
    def create_issue(_attrs, _opts), do: {:error, :not_found, %{reason: "no provider"}}
  end

  defmodule TimeoutAdapter do
    @moduledoc false

    def metadata(_opts) do
      {:ok,
       %{
         provider: "stub",
         provider_project_id: "p",
         states: [%{id: "s-1", name: "Todo", display_column: "待办", active: true, terminal: false}],
         assignees: [],
         labels: [],
         capabilities: [],
         fetched_at: "2026-09-14T10:38:00Z",
         stale: false
       }}
    end

    def list_issues(_opts), do: {:ok, []}
    def get_issue(_id, _opts), do: {:error, :not_found, %{}}
    def create_issue(_attrs, _opts), do: {:error, :timeout, %{}}
  end
end
