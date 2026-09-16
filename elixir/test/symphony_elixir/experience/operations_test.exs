defmodule SymphonyElixir.Experience.OperationsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.{DemoAdapter, Operations, Project, Store}

  @project_id "embedded-lab-demo"
  @actor %{kind: "human", id: "local-operator", display_name: "本机操作者"}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-ops-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: store,
      start: {Store, :start_link, [[name: store, data_root: root]]},
      restart: :transient
    })

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
        workspace_root: "/tmp/workspaces",
        # Human Review is the demonstration project's non-active, non-terminal
        # state, which is exactly what a persistent pause needs.
        paused_state: "Human Review"
      },
      overrides
    )
  end

  defp decision_payload(overrides) do
    Map.merge(
      %{
        "id" => "decision-EMB-40",
        "project_id" => @project_id,
        "revision" => 1,
        "issue_id" => "demo-issue-40",
        "problem_case_ids" => ["DISP-12"],
        "options" => [
          %{"id" => "A", "title" => "延后释放", "proposal" => "保持单缓冲", "tradeoffs" => ["Agent 建议"], "evidence_ids" => ["E-017"], "remaining_validation" => ["仍需真机验证"]},
          %{"id" => "B", "title" => "双缓冲", "proposal" => "隔离读写", "tradeoffs" => ["增加内存占用"], "evidence_ids" => ["E-017"], "remaining_validation" => ["内存预算"]}
        ],
        "status" => "draft",
        "selected_option_id" => nil,
        "constraints" => ["优先保证稳定性"],
        "plan_revision" => "r12",
        "actor" => %{"kind" => "agent", "id" => "run-1", "display_name" => "Driver Agent"},
        "limitations" => ["现有证据尚不足以确认根因。"],
        "supersedes" => nil
      },
      overrides
    )
  end

  defp retry_store do
    root = Path.join(System.tmp_dir!(), "symphony-ops-extra-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = Module.concat(__MODULE__, :"ExtraStore#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: name, data_root: root})
    on_exit(fn -> File.rm_rf(root) end)
    name
  end

  defp seed_decision(context, overrides \\ %{}) do
    payload = decision_payload(overrides)
    {:ok, _} = Store.append(@project_id, "Decision", payload["id"], 0, payload, @actor, server: context.store)
    payload
  end

  defp pause_request(key, issue_id \\ "demo-issue-42") do
    %{
      action: "pause_issue",
      idempotency_key: key,
      expected_revision: 1,
      payload: %{"issue_id" => issue_id, "provider_version" => "v1"}
    }
  end

  describe "pause and resume" do
    test "writes the native pause state and reads it back", %{store: store, demo: demo} = context do
      assert {:ok, operation} = Operations.submit(project(context), @actor, pause_request("key-pause-0001"), opts(context))

      assert operation["status"] == "applied"
      assert operation["result_entity_id"] == "demo-issue-42"

      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "Human Review"
      assert store == context.store
    end

    test "refuses to pause when no pause state is configured", %{store: store} = context do
      unconfigured = project(context, %{paused_state: nil})

      assert {:ok, operation} = Operations.submit(unconfigured, @actor, pause_request("key-pause-0002"), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "unsupported_capability"
      assert store == context.store
    end

    test "never claims a pause the provider did not reflect", %{store: store} = context do
      ignoring = project(context, adapter: __MODULE__.IgnoringTransitionAdapter)

      assert {:ok, operation} = Operations.submit(ignoring, @actor, pause_request("key-pause-0003"), opts(context))

      assert operation["status"] == "outcome_unknown"
      assert store == context.store
    end

    test "resumes to an explicitly requested active state", %{store: store, demo: demo} = context do
      assert {:ok, _} = Operations.submit(project(context), @actor, pause_request("key-pause-0004"), opts(context))

      resume = %{
        action: "resume_issue",
        idempotency_key: "key-resume-0001",
        expected_revision: 1,
        payload: %{"issue_id" => "demo-issue-42", "provider_version" => "v1", "target_state" => "In Progress"}
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, resume, opts(context))
      assert operation["status"] == "applied"

      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "In Progress"
      assert store == context.store
    end

    test "a full data root refuses a second writer, naming the holder", context do
      root = Store.data_root(context.store)
      other = Module.concat(__MODULE__, :"Second#{System.unique_integer([:positive])}")

      # A store that cannot take the lock refuses to start; because the starter is
      # linked, that refusal also arrives as an exit signal, so this process traps
      # exits for the duration of the check.
      previous = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous) end)

      assert {:error, {:store_start_failed, :data_root_locked, %{holder: holder}}} =
               Store.start_link(name: other, data_root: root)

      assert holder =~ System.pid()
    end

    test "a restart neither resumes a paused issue nor forgets the receipt", context do
      project = project(context)

      assert {:ok, paused} = Operations.submit(project, @actor, pause_request("key-pause-restart"), opts(context))
      assert paused["status"] == "applied"

      # The records are the only truth about what the workbench did, so a restart
      # is measured against the bytes on disk first.
      root = Store.data_root(context.store)
      journal = Path.join([root, "projects", @project_id, "records.jsonl"])
      assert File.read!(journal) =~ "key-pause-restart"

      :ok = stop_supervised!(context.store)

      # A restart inside one test process is still the same OS process, and the
      # lock names the OS process that holds it — so it is cleared here the way an
      # operator would after a crash. That the lock is honoured while a holder is
      # alive is asserted above.
      File.rm(Path.join(root, "store.lock"))

      start_supervised!(%{
        id: context.store,
        start: {Store, :start_link, [[name: context.store, data_root: root]]},
        restart: :transient
      })

      # The provider still holds the paused state: nothing in the workbench turned
      # the issue back on while it was starting.
      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: context.demo)
      assert issue.state == "Human Review"

      # The receipt survives, under the same idempotency key.
      assert {:ok, reloaded} = Operations.get(project, paused["id"], opts(context))
      assert reloaded["idempotency_key"] == "key-pause-restart"
      assert reloaded["status"] == "applied"

      # Re-sending the same request after the restart is the same operation: not a
      # second pause, and not a resume.
      assert {:ok, again} = Operations.submit(project, @actor, pause_request("key-pause-restart"), opts(context))
      assert again["id"] == paused["id"]
      assert again["action"] == "pause_issue"

      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: context.demo)
      assert issue.state == "Human Review"
    end

    test "refuses a resume without a target state", %{store: store} = context do
      resume = %{
        action: "resume_issue",
        idempotency_key: "key-resume-0002",
        expected_revision: 1,
        payload: %{"issue_id" => "demo-issue-42", "provider_version" => "v1"}
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, resume, opts(context))
      assert operation["status"] == "failed"
      assert operation["error_code"] == "invalid_payload"
      assert store == context.store
    end
  end

  describe "adopting a decision" do
    defp adopt_request(key, overrides \\ %{}) do
      %{
        action: "adopt_decision",
        idempotency_key: key,
        expected_revision: 1,
        payload:
          Map.merge(
            %{
              "issue_id" => "demo-issue-42",
              "provider_version" => "v1",
              "decision_id" => "decision-EMB-40",
              "option_id" => "A",
              "resume_after_apply" => false,
              "resume_target_state" => nil
            },
            overrides
          )
      }
    end

    test "records an adopted revision, pauses, and publishes the plan", %{store: store, demo: demo} = context do
      seed_decision(context)

      assert {:ok, operation} = Operations.submit(project(context), @actor, adopt_request("key-adopt-0001"), opts(context))

      assert operation["status"] == "applied"
      assert operation["result_entity_id"] == "decision-EMB-40"

      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.entity_revision == 2
      assert decision.payload["status"] == "adopted"
      assert decision.payload["selected_option_id"] == "A"
      assert decision.payload["plan_revision"] == "r13"
      assert decision.payload["actor"]["kind"] == "human"

      # The issue is paused before the plan is published, and the plan reference
      # is what the next executor will read.
      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "Human Review"

      assert {:ok, %{plan: plan}} = DemoAdapter.get_workpad("demo-issue-42", demo_state: demo)
      assert plan["decision_id"] == "decision-EMB-40"
      assert plan["plan_revision"] == "r13"
      assert String.length(plan["decision_sha256"]) == 64
    end

    test "keeps the decision and reports which stage failed", %{store: store} = context do
      seed_decision(context)
      no_workpad = project(context, adapter: __MODULE__.NoWorkpadAdapter)

      assert {:ok, operation} = Operations.submit(no_workpad, @actor, adopt_request("key-adopt-0002"), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "unsupported_capability"

      # The human decision is durable even though the workflow update failed.
      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.payload["status"] == "adopted"
      assert store == context.store
    end

    test "refuses an option that is not on the decision", %{store: store} = context do
      seed_decision(context)

      assert {:ok, operation} =
               Operations.submit(project(context), @actor, adopt_request("key-adopt-0003", %{"option_id" => "Z"}), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "unknown_option"
      assert store == context.store
    end

    test "refuses a decision that was already adopted", %{store: store} = context do
      seed_decision(context, %{"status" => "adopted", "selected_option_id" => "A"})

      assert {:ok, operation} = Operations.submit(project(context), @actor, adopt_request("key-adopt-0004"), opts(context))
      assert operation["error_code"] == "already_adopted"
      assert store == context.store
    end

    test "reports an unknown decision instead of inventing one", %{store: store} = context do
      assert {:ok, operation} =
               Operations.submit(project(context), @actor, adopt_request("key-adopt-0005", %{"decision_id" => "missing"}), opts(context))

      assert operation["error_code"] == "not_found"
      assert store == context.store
    end

    test "resumes only when the request asked for it", %{store: store, demo: demo} = context do
      seed_decision(context)

      resumed =
        adopt_request("key-adopt-0006", %{
          "resume_after_apply" => true,
          "resume_target_state" => "In Progress"
        })

      assert {:ok, operation} = Operations.submit(project(context), @actor, resumed, opts(context))
      assert operation["status"] == "applied"

      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "In Progress"
      assert store == context.store
    end
  end

  describe "adjusting constraints" do
    test "edits a draft candidate without publishing a plan", %{store: store, demo: demo} = context do
      seed_decision(context)

      request = %{
        action: "adjust_constraints",
        idempotency_key: "key-constraints-0001",
        expected_revision: 1,
        payload: %{
          "issue_id" => "demo-issue-42",
          "provider_version" => "v1",
          "decision_id" => "decision-EMB-40",
          "constraints" => ["稳定性优先", "不做双缓冲"],
          "resume_after_apply" => false,
          "resume_target_state" => nil
        }
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["status"] == "applied"

      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.payload["status"] == "draft"
      assert decision.payload["constraints"] == ["稳定性优先", "不做双缓冲"]
      assert decision.payload["plan_revision"] == "r12"

      # A draft edit must not change what the executor will read.
      assert {:ok, nil} = DemoAdapter.get_workpad("demo-issue-42", demo_state: demo)
    end

    test "creates a new adopted revision for an already adopted decision", %{store: store, demo: demo} = context do
      seed_decision(context)
      assert {:ok, _} = Operations.submit(project(context), @actor, adopt_request("key-adopt-0007"), opts(context))

      request = %{
        action: "adjust_constraints",
        idempotency_key: "key-constraints-0002",
        expected_revision: 2,
        payload: %{
          "issue_id" => "demo-issue-42",
          "provider_version" => "v1",
          "decision_id" => "decision-EMB-40",
          "constraints" => ["稳定性优先", "新增内存占用需说明"],
          "resume_after_apply" => false,
          "resume_target_state" => nil
        }
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["status"] == "applied"

      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.entity_revision == 3
      assert decision.payload["status"] == "adopted"
      assert decision.payload["selected_option_id"] == "A"
      assert decision.payload["plan_revision"] == "r14"
      assert decision.payload["supersedes"] == "decision-EMB-40"

      # A constraint change on an adopted plan pauses the issue again.
      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "Human Review"
      assert store == context.store
    end

    test "refuses an empty constraint list", %{store: store} = context do
      seed_decision(context)

      request = %{
        action: "adjust_constraints",
        idempotency_key: "key-constraints-0004",
        expected_revision: 1,
        payload: %{
          "issue_id" => "demo-issue-42",
          "provider_version" => "v1",
          "decision_id" => "decision-EMB-40",
          "constraints" => [],
          "resume_after_apply" => false,
          "resume_target_state" => nil
        }
      }

      assert {:error, :invalid_payload, %{action: "adjust_constraints"}} = Operations.submit(project(context), @actor, request, opts(context))
      assert length(Store.list_revisions(@project_id, "Decision", server: store)) == 1
    end

    test "refuses an adopt with no chosen option", %{store: store} = context do
      seed_decision(context)

      assert {:error, :invalid_payload, %{action: "adopt_decision"}} =
               Operations.submit(project(context), @actor, adopt_request("key-adopt-0020", %{"option_id" => ""}), opts(context))

      assert store == context.store
    end

    test "refuses to edit a superseded decision", %{store: store} = context do
      seed_decision(context, %{"status" => "superseded"})

      request = %{
        action: "adjust_constraints",
        idempotency_key: "key-constraints-0003",
        expected_revision: 1,
        payload: %{
          "issue_id" => "demo-issue-42",
          "provider_version" => "v1",
          "decision_id" => "decision-EMB-40",
          "constraints" => ["x"],
          "resume_after_apply" => false,
          "resume_target_state" => nil
        }
      }

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["error_code"] == "not_editable"
      assert store == context.store
    end
  end

  describe "direction-change edge cases" do
    test "carries explicit constraints into the adopted revision", %{store: store} = context do
      seed_decision(context)

      request = adopt_request("key-adopt-0010", %{"constraints" => ["只做稳定性修复"], "limitations" => ["待复测"]})

      assert {:ok, operation} = Operations.submit(project(context), @actor, request, opts(context))
      assert operation["status"] == "applied"

      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.payload["constraints"] == ["只做稳定性修复"]
      assert decision.payload["limitations"] == ["待复测"]
    end

    test "numbers a plan revision from whatever the decision carried", context do
      for {given, expected} <- [{"v1", "r1"}, {"rX", "r1"}, {"r7", "r8"}, {nil, "r1"}] do
        store = retry_store()
        seed = seed_decision(%{store: store}, %{"plan_revision" => given})

        project = %Project{
          project_id: @project_id,
          mode: "demo",
          adapter: DemoAdapter,
          store: store,
          display_states: [],
          workspace_root: "/tmp/workspaces",
          paused_state: "Human Review"
        }

        assert {:ok, operation} =
                 Operations.submit(
                   project,
                   @actor,
                   adopt_request("key-adopt-plan-#{expected}-#{given}"),
                   demo_state: context.demo
                 )

        assert operation["status"] == "applied", inspect(operation)

        {:ok, decision} = Store.get(@project_id, "Decision", seed["id"], server: store)
        assert decision.payload["plan_revision"] == expected
      end
    end

    test "reports a provider that refuses the pause", %{store: store} = context do
      refusing = project(context, adapter: __MODULE__.RefusingTransitionAdapter)

      assert {:ok, operation} = Operations.submit(refusing, @actor, pause_request("key-pause-0010"), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "provider_unavailable"
      assert store == context.store
    end

    test "reports a resume the provider never reflected", %{store: store, demo: demo} = context do
      seed_decision(context)

      # The pause lands, the resume does not: the two stages must be reported
      # separately rather than as one success.
      pause_only = project(context, adapter: __MODULE__.PauseOnlyAdapter)

      request =
        adopt_request("key-adopt-0011", %{
          "resume_after_apply" => true,
          "resume_target_state" => "In Progress"
        })

      assert {:ok, operation} = Operations.submit(pause_only, @actor, request, opts(context))

      assert operation["status"] == "outcome_unknown", inspect(operation["steps"])

      # The decision was still recorded, and the issue stayed paused.
      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.payload["status"] == "adopted"

      {:ok, issue} = DemoAdapter.get_issue("demo-issue-42", demo_state: demo)
      assert issue.state == "Human Review"
      assert store == context.store
    end

    test "stops at the pause stage when the provider refuses it", %{store: store} = context do
      seed_decision(context)
      refusing = project(context, adapter: __MODULE__.RefusingTransitionAdapter)

      assert {:ok, operation} = Operations.submit(refusing, @actor, adopt_request("key-adopt-0014"), opts(context))

      assert operation["status"] == "failed"
      assert operation["error_code"] == "provider_unavailable"

      # The adopted decision is durable; only the workflow step failed.
      {:ok, decision} = Store.get(@project_id, "Decision", "decision-EMB-40", server: store)
      assert decision.payload["status"] == "adopted"
      assert store == context.store
    end

    test "reports an unreadable decision as not found", %{store: store} = context do
      # Nothing was ever recorded under this id, which is the same outcome as a
      # record the store cannot read.
      assert {:ok, operation} =
               Operations.submit(project(context), @actor, adopt_request("key-adopt-0013", %{"decision_id" => "gone"}), opts(context))

      assert operation["error_code"] == "not_found"
      assert store == context.store
    end

    test "reports an unreadable store while loading a decision", %{store: store} = context do
      broken = project(context, %{project_id: "../escape"})

      # The intent record itself cannot be written, so there is no receipt to
      # hand back — the caller gets the store error rather than a fake receipt.
      assert {:error, :invalid_project_id, _} = Operations.submit(broken, @actor, adopt_request("key-adopt-0012"), opts(context))
      assert store == context.store
    end
  end

  defmodule PauseOnlyAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter
    defdelegate update_workpad_plan(id, plan, opts), to: DemoAdapter

    # Accepts a pause and reports it back; silently keeps the old state for any
    # other target, which must not read as success.
    def transition(id, state, opts) do
      if state == "Human Review" do
        DemoAdapter.transition(id, state, opts)
      else
        DemoAdapter.get_issue(id, opts)
      end
    end
  end

  defmodule RefusingTransitionAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter

    def transition(_id, _state, _opts), do: {:error, :provider_unavailable, %{reason: "down"}}
  end

  defmodule IgnoringTransitionAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter

    # Accepts the write and reports the old state, which must not read as success.
    def transition(_id, _state, _opts), do: {:ok, %{id: "demo-issue-42", native_state: "In Progress"}}
  end

  defmodule NoWorkpadAdapter do
    @moduledoc false
    defdelegate metadata(opts), to: DemoAdapter
    defdelegate list_issues(opts), to: DemoAdapter
    defdelegate get_issue(id, opts), to: DemoAdapter
    defdelegate create_issue(attrs, opts), to: DemoAdapter
    defdelegate transition(id, state, opts), to: DemoAdapter
    defdelegate comment(id, body, opts), to: DemoAdapter
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
    assert Operations.supported_actions() ==
             ~w(create_issue change_issue_state pause_issue resume_issue adopt_decision adjust_constraints
                comment request_evidence review)
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
