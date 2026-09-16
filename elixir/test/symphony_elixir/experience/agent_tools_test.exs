defmodule SymphonyElixir.Experience.AgentToolsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Experience.{AgentTools, Architecture, Canonical, DemoAdapter, Project, Store}
  alias SymphonyElixir.Tracker.Issue

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-tools-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    if pid = Process.whereis(Store), do: GenServer.stop(pid)
    if pid = Process.whereis(DemoAdapter.State), do: GenServer.stop(pid)

    store =
      start_supervised!(%{id: Store, start: {Store, :start_link, [[data_root: Path.join(root, "data")]]}})

    _ = store

    start_supervised!({DemoAdapter, []})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      workspace_root: workspace,
      workbench: %{
        "enabled" => true,
        "mode" => "demo",
        "project_id" => "embedded-lab-demo",
        "data_root" => Path.join(root, "data"),
        "display_states" => ["待办", "进行中", "待审阅", "已完成"]
      }
    )

    on_exit(fn ->
      if pid = Process.whereis(Store), do: GenServer.stop(pid)
      if pid = Process.whereis(DemoAdapter.State), do: GenServer.stop(pid)
      File.rm_rf(root)
    end)

    %{root: root, workspace: workspace}
  end

  defp issue do
    %Issue{id: "demo-issue-42", identifier: "EMB-42", title: "修复显示画面偶发撕裂", state: "In Progress"}
  end

  defp tool_binding, do: AgentTools.bind(run_id: "thread-7")

  defp run(tool, arguments, opts \\ []) do
    binding = Keyword.get(opts, :binding, tool_binding())
    issue = Keyword.get(opts, :issue, issue())

    tool
    |> AgentTools.execute(arguments, binding, issue: issue, run_id: "thread-7")
    |> decode()
  end

  defp decode(%{"success" => success, "output" => output} = envelope) do
    assert is_list(envelope["contentItems"])
    assert [%{"type" => "inputText", "text" => ^output}] = envelope["contentItems"]

    Map.put(Jason.decode!(output), "envelope_success", success)
  end

  defp problem_case(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "DISP-12",
        "project_id" => "embedded-lab-demo",
        "revision" => 1,
        "issue_ids" => ["demo-issue-42"],
        "component_ids" => ["display-driver"],
        "symptom" => "连续切换画面时出现局部撕裂。",
        "claims" => [],
        "experiments" => [],
        "current_conclusion" => "",
        "next_step" => "",
        "state" => %{
          "implementation_status" => "building",
          "verification_status" => "unverified",
          "human_review_status" => "unseen",
          "agent_endorsed" => false
        },
        "limitations" => []
      },
      overrides
    )
  end

  defp report_request(entity_type, entity, overrides \\ %{}) do
    Map.merge(
      %{
        "idempotency_key" => "key-report-0001",
        "expected_revision" => 0,
        "report" => %{"entity_type" => entity_type, "entity" => entity}
      },
      overrides
    )
  end

  describe "specs" do
    test "advertises the canonical contract with every reference resolved" do
      specs = AgentTools.tool_specs()

      assert Enum.map(specs, & &1["name"]) == [
               "engineering_report",
               "engineering_read",
               "engineering_plan_loaded",
               "engineering_architecture_publish",
               "engineering_blob_import",
               "engineering_device_action",
               "engineering_device_lease"
             ]

      assert Enum.all?(specs, &is_binary(&1["description"]))
      refute inspect(specs) =~ "$ref"

      report = Enum.find(specs, &(&1["name"] == "engineering_report"))
      entity_types = report["inputSchema"]["properties"]["report"]["oneOf"]
      assert Enum.map(entity_types, & &1["properties"]["entity_type"]["const"]) == ["ProblemCase", "Evidence", "Validation", "Decision"]

      # A resolved shared definition carries its own constraints, not just a name.
      claim = report["inputSchema"]["properties"]["report"]["oneOf"] |> hd() |> get_in(["properties", "entity", "properties", "claims", "items"])
      assert claim["required"] == ["id", "statement", "status", "supporting_evidence_ids", "contradicting_evidence_ids", "evidence_missing", "limitations"]
    end

    test "declares which advertised tools this build actually implements" do
      assert AgentTools.supported_tools() ==
               ~w(engineering_report engineering_read engineering_plan_loaded engineering_blob_import engineering_architecture_publish)
    end

    test "binds no tools at all when the workbench is off" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_api_token: nil,
        tracker_project_slug: nil,
        workbench: %{"enabled" => false, "mode" => "demo"}
      )

      assert %{tool_specs: [], context: nil} = AgentTools.bind()

      assert %{"success" => false, "output" => output} =
               AgentTools.execute("engineering_read", %{}, %{context: nil}, issue: issue())

      assert Jason.decode!(output)["error"]["code"] == "workbench_unavailable"
    end
  end

  describe "engineering_report" do
    test "records a case revision attributed to the calling run" do
      result = run("engineering_report", report_request("ProblemCase", problem_case()))

      assert result["ok"]
      assert result["entity_id"] == "DISP-12"
      assert result["revision"] == 1
      assert result["project_seq"] >= 1
      assert result["envelope_success"]

      assert {:ok, record} = Store.get("embedded-lab-demo", "ProblemCase", "DISP-12")
      assert record.actor["kind"] == "agent"
      assert record.actor["id"] == "thread-7"

      # The report also lands on the issue timeline, bound to the same run.
      assert [event | _] = Store.list("embedded-lab-demo", "Event")
      assert event.payload["run_id"] == "thread-7"
      assert event.payload["type"] == "problemcase.updated"
    end

    test "refuses a stale expected revision" do
      assert run("engineering_report", report_request("ProblemCase", problem_case()))["ok"]

      stale =
        run(
          "engineering_report",
          report_request("ProblemCase", problem_case(%{"symptom" => "改过的症状"}), %{
            "expected_revision" => 0,
            "idempotency_key" => "key-report-0002"
          })
        )

      assert stale["error"]["code"] == "revision_conflict"
      refute stale["envelope_success"]

      assert {:ok, record} = Store.get("embedded-lab-demo", "ProblemCase", "DISP-12")
      assert record.payload["symptom"] == "连续切换画面时出现局部撕裂。"
    end

    test "never writes a human verdict on behalf of the machine" do
      claimed =
        problem_case(%{
          "state" => %{
            "implementation_status" => "integrated",
            "verification_status" => "passed",
            "human_review_status" => "accepted",
            "agent_endorsed" => true
          }
        })

      result = run("engineering_report", report_request("ProblemCase", claimed))

      assert result["error"]["code"] == "human_verdict_not_allowed"

      assert Store.get("embedded-lab-demo", "ProblemCase", "DISP-12") ==
               {:error, :not_found, %{entity_type: "ProblemCase", entity_id: "DISP-12"}}
    end

    test "cannot clear a human review that already happened" do
      assert run("engineering_report", report_request("ProblemCase", problem_case()))["ok"]

      {:ok, _} =
        Store.append(
          "embedded-lab-demo",
          "ProblemCase",
          "DISP-12",
          1,
          %{
            "symptom" => "连续切换画面时出现局部撕裂。",
            "state" => %{"human_review_status" => "changes_requested"},
            "limitations" => []
          },
          %{kind: "human", id: "operator", display_name: "本机操作者"}
        )

      retry =
        run(
          "engineering_report",
          report_request("ProblemCase", problem_case(%{"current_conclusion" => "补充了观察"}), %{
            "expected_revision" => 2,
            "idempotency_key" => "key-report-0003"
          })
        )

      assert retry["ok"]
      assert retry["revision"] == 3

      assert {:ok, record} = Store.get("embedded-lab-demo", "ProblemCase", "DISP-12")
      assert record.payload["state"]["human_review_status"] == "changes_requested"
      assert record.payload["current_conclusion"] == "补充了观察"
    end

    test "refuses an entity type the tools do not own" do
      result = run("engineering_report", report_request("Device", %{"id" => "d-1"}))

      assert result["error"]["code"] == "unsupported_entity_type"
    end

    test "refuses malformed arguments without writing" do
      assert run("engineering_report", %{})["error"]["code"] == "invalid_arguments"

      assert run("engineering_report", report_request("ProblemCase", problem_case(), %{"expected_revision" => -1}))["error"]["code"] ==
               "invalid_expected_revision"

      assert Store.get("embedded-lab-demo", "ProblemCase", "DISP-12") ==
               {:error, :not_found, %{entity_type: "ProblemCase", entity_id: "DISP-12"}}
    end

    test "refuses a call with no bound issue" do
      result = run("engineering_report", report_request("ProblemCase", problem_case()), issue: nil)

      assert result["error"]["code"] == "missing_issue_scope"
    end

    test "accepts arguments delivered as a JSON string" do
      arguments = Jason.encode!(report_request("ProblemCase", problem_case()))

      assert %{"success" => true} =
               AgentTools.execute("engineering_report", arguments, tool_binding(), issue: issue(), run_id: "thread-7")
    end

    test "refuses arguments that are not a JSON object" do
      assert run("engineering_read", "[1,2,3]")["error"]["code"] == "invalid_arguments"
      assert run("engineering_read", 42)["error"]["code"] == "invalid_arguments"
      assert run("engineering_read", "{not json")["error"]["code"] == "invalid_arguments"
    end
  end

  describe "engineering_read" do
    test "reads a stored record back" do
      assert run("engineering_report", report_request("ProblemCase", problem_case()))["ok"]

      result = run("engineering_read", %{"entity_type" => "ProblemCase", "entity_id" => "DISP-12"})

      assert result["ok"]
      assert result["revision"] == 1
      assert result["entity"]["symptom"] == "连续切换画面时出现局部撕裂。"
      assert result["recorded_at"] =~ "T"
    end

    test "reports a miss and an unknown type distinctly" do
      assert run("engineering_read", %{"entity_type" => "Evidence", "entity_id" => "missing"})["error"]["code"] == "not_found"

      assert run("engineering_read", %{"entity_type" => "Device", "entity_id" => "d-1"})["error"]["code"] ==
               "unsupported_entity_type"
    end
  end

  describe "engineering_plan_loaded" do
    test "records the plan a run actually read, bound to that run" do
      plan = %{
        "decision_id" => "DISP-12",
        "decision_revision" => 3,
        "decision_sha256" => String.duplicate("a", 64),
        "plan_revision" => "r13",
        "constraints" => ["稳定性优先"],
        "remaining_validation" => ["真机复测"]
      }

      {:ok, _} = DemoAdapter.update_workpad_plan("demo-issue-42", plan)

      result =
        run("engineering_plan_loaded", %{
          "decision_id" => "DISP-12",
          "plan_revision" => "r13",
          "decision_sha256" => AgentTools.plan_sha(plan),
          "idempotency_key" => "key-plan-0001"
        })

      assert result["ok"]

      assert [event | _] = Store.list("embedded-lab-demo", "Event")
      assert event.payload["type"] == "plan.loaded"
      assert event.payload["run_id"] == "thread-7"
      assert event.payload["payload"]["plan_revision"] == "r13"
    end

    test "refuses a plan that does not match the workpad" do
      plan = %{"decision_id" => "DISP-12", "plan_revision" => "r13", "decision_sha256" => String.duplicate("a", 64)}
      {:ok, _} = DemoAdapter.update_workpad_plan("demo-issue-42", plan)

      wrong_revision =
        run("engineering_plan_loaded", %{
          "decision_id" => "DISP-12",
          "plan_revision" => "r99",
          "decision_sha256" => AgentTools.plan_sha(plan),
          "idempotency_key" => "key-plan-0002"
        })

      assert wrong_revision["error"]["code"] == "plan_mismatch"

      wrong_hash =
        run("engineering_plan_loaded", %{
          "decision_id" => "DISP-12",
          "plan_revision" => "r13",
          "decision_sha256" => String.duplicate("b", 64),
          "idempotency_key" => "key-plan-0003"
        })

      assert wrong_hash["error"]["code"] == "plan_hash_mismatch"

      wrong_decision =
        run("engineering_plan_loaded", %{
          "decision_id" => "DISP-99",
          "plan_revision" => "r13",
          "decision_sha256" => AgentTools.plan_sha(plan),
          "idempotency_key" => "key-plan-0004"
        })

      assert wrong_decision["error"]["code"] == "plan_mismatch"

      assert Store.list("embedded-lab-demo", "Event") == []
    end

    test "reports a missing workpad and a provider without one" do
      assert run("engineering_plan_loaded", %{
               "decision_id" => "DISP-12",
               "plan_revision" => "r13",
               "decision_sha256" => String.duplicate("a", 64),
               "idempotency_key" => "key-plan-0005"
             })["error"]["code"] == "workpad_missing"

      base = tool_binding()
      project = Map.put(base.context.project, :adapter, __MODULE__.NoWorkpadAdapter)
      no_workpad = Map.put(base, :context, Map.put(base.context, :project, project))

      result =
        run(
          "engineering_plan_loaded",
          %{
            "decision_id" => "DISP-12",
            "plan_revision" => "r13",
            "decision_sha256" => String.duplicate("a", 64),
            "idempotency_key" => "key-plan-0006"
          },
          binding: no_workpad
        )

      assert result["error"]["code"] == "unsupported_capability"
    end

    defmodule NoWorkpadAdapter do
      @moduledoc false
    end
  end

  describe "engineering_architecture_publish" do
    @revision "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"

    defp architect_upload(overrides \\ %{}) do
      {:ok, project} = Project.load()

      ir = %{
        "components" => [%{"id" => "core", "label" => "Core"}],
        "connections" => []
      }

      {:ok, ir_receipt} = Store.put_blob(project.project_id, Canonical.encode!(ir), "application/json")
      {:ok, html_receipt} = Store.put_blob(project.project_id, "<html><body><svg></svg></body></html>", "text/html")

      deliver = %{
        "ok" => true,
        "validation" => %{"checksPassed" => 9, "checkCount" => 9, "compositionStatus" => "pass", "errors" => 0, "warnings" => 0}
      }

      {:ok, deliver_receipt} = Store.put_blob(project.project_id, Canonical.encode!(deliver), "application/json")

      manifest =
        Map.merge(
          %{
            "schema_version" => "1.0",
            "project_id" => project.project_id,
            "artifact_id" => "art-1",
            "kind" => "source",
            "source_repo_url" => "https://github.com/rayheto/symphony_embedded",
            "source_revision" => @revision,
            "base_revision" => nil,
            "plan_revision" => nil,
            "plan_sources" => [],
            "skill_commit" => Architecture.skill_commit(),
            "ir_sha256" => ir_receipt["sha256"],
            "html_sha256" => html_receipt["sha256"],
            "deliver_receipt_sha256" => deliver_receipt["sha256"],
            "browser_receipt_sha256" => nil,
            "visual_review_sha256" => nil,
            "components" => [
              %{
                "id" => "core",
                "label" => "Core",
                "layers" => ["L2"],
                "source_refs" => [
                  %{"kind" => "git", "locator" => "elixir/lib/core.ex", "repo_revision" => @revision, "line" => 1, "end_line" => 9}
                ],
                "issue_ids" => [],
                "problem_case_ids" => [],
                "evidence_ids" => [],
                "implementation_status" => "planned",
                "verification_status" => "unverified"
              }
            ],
            "limitations" => [],
            "relationships" => []
          },
          overrides
        )

      {:ok, manifest_receipt} = Store.put_blob(project.project_id, Canonical.encode!(manifest), "application/json")

      %{
        "artifact_id" => manifest["artifact_id"],
        "manifest_blob_sha256" => manifest_receipt["sha256"],
        "ir_blob_sha256" => ir_receipt["sha256"],
        "html_blob_sha256" => html_receipt["sha256"]
      }
    end

    test "publishes a delivery the host verified itself" do
      arguments = Map.put(architect_upload(), "idempotency_key", "key-arch-0001")

      result = run("engineering_architecture_publish", arguments)

      assert result["ok"]
      assert result["artifact"]["generation_status"] == "succeeded"
      assert [%{"id" => "core"}] = result["artifact"]["components"]
    end

    test "refuses a delivery whose manifest overstates a component" do
      arguments =
        architect_upload(%{
          "components" => [
            %{
              "id" => "core",
              "label" => "Core",
              "layers" => ["L2"],
              "source_refs" => [],
              "issue_ids" => [],
              "problem_case_ids" => [],
              "evidence_ids" => [],
              "implementation_status" => "integrated",
              "verification_status" => "passed"
            }
          ]
        })
        |> Map.put("idempotency_key", "key-arch-0002")

      result = run("engineering_architecture_publish", arguments)

      assert result["error"]["code"] == "implementation_overstated"
    end

    test "reads every named file back instead of trusting the hash it was given" do
      arguments =
        architect_upload()
        |> Map.put("html_blob_sha256", String.duplicate("a", 64))
        |> Map.put("idempotency_key", "key-arch-0003")

      assert run("engineering_architecture_publish", arguments)["error"]["code"] == "blob_missing"
    end

    test "reports a missing argument instead of guessing one" do
      assert run("engineering_architecture_publish", %{"artifact_id" => "art-1"})["error"]["code"] == "invalid_arguments"
    end
  end

  describe "engineering_blob_import" do
    setup %{workspace: workspace} do
      bytes = "10:36:01.460  buffer_reuse buf=01\n"
      File.write!(Path.join(workspace, "capture.txt"), bytes)

      %{bytes: bytes, sha: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end

    test "copies a workspace file into the durable store", %{sha: sha, bytes: bytes} do
      result =
        run("engineering_blob_import", %{
          "relative_path" => "capture.txt",
          "expected_sha256" => sha,
          "media_type" => "text/plain",
          "idempotency_key" => "key-blob-0001"
        })

      assert result["ok"]
      assert result["blob"]["sha256"] == sha
      assert result["blob"]["size_bytes"] == byte_size(bytes)
      assert {:ok, ^bytes} = Store.get_blob("embedded-lab-demo", sha)
    end

    test "refuses a file whose bytes do not match the stated digest", %{bytes: bytes} do
      File.write!(Path.join(warehouse_path(), "capture.txt"), bytes)

      result =
        run("engineering_blob_import", %{
          "relative_path" => "capture.txt",
          "expected_sha256" => String.duplicate("0", 64),
          "media_type" => "text/plain",
          "idempotency_key" => "key-blob-0002"
        })

      assert result["error"]["code"] == "digest_mismatch"
    end

    test "refuses a path outside the workspace" do
      assert run("engineering_blob_import", %{
               "relative_path" => "../secret.txt",
               "expected_sha256" => String.duplicate("0", 64),
               "media_type" => "text/plain",
               "idempotency_key" => "key-blob-0003"
             })["error"]["code"] == "path_outside_workspace"
    end

    test "reports an unreadable file instead of a receipt" do
      assert run("engineering_blob_import", %{
               "relative_path" => "missing.bin",
               "expected_sha256" => String.duplicate("0", 64),
               "media_type" => "application/octet-stream",
               "idempotency_key" => "key-blob-0004"
             })["error"]["code"] == "unreadable_workspace_file"
    end

    test "refuses a file larger than the material limit" do
      path = Path.join(warehouse_path(), "huge.bin")
      File.write!(path, :binary.copy("a", 67_108_865))

      result =
        run("engineering_blob_import", %{
          "relative_path" => "huge.bin",
          "expected_sha256" => String.duplicate("0", 64),
          "media_type" => "application/octet-stream",
          "idempotency_key" => "key-blob-0005"
        })

      assert result["error"]["code"] == "blob_too_large"
      File.rm(path)
    end

    defp warehouse_path do
      %{context: %{project: project}} = tool_binding()
      project.workspace_root
    end
  end

  describe "scope and failure reporting" do
    test "uses the bound defaults when no options are given" do
      # Without an issue the tools cannot bind a scope, and must say so rather
      # than writing an unattributed record.
      assert %{"success" => false, "output" => output} =
               AgentTools.execute("engineering_read", %{}, tool_binding())

      assert Jason.decode!(output)["error"]["code"] == "missing_issue_scope"
    end

    test "reports an unreadable store instead of an empty record" do
      base = tool_binding()
      broken_project = Map.put(base.context.project, :project_id, "../escape")
      broken = Map.put(base, :context, Map.put(base.context, :project, broken_project))

      assert run("engineering_read", %{"entity_type" => "Evidence", "entity_id" => "E-017"}, binding: broken)["error"]["code"] ==
               "invalid_project_id"
    end

    test "reports a provider that cannot read its workpad" do
      base = tool_binding()
      project = Map.put(base.context.project, :adapter, __MODULE__.BrokenWorkpadAdapter)
      broken = Map.put(base, :context, Map.put(base.context, :project, project))

      result =
        run(
          "engineering_plan_loaded",
          %{
            "decision_id" => "DISP-12",
            "plan_revision" => "r13",
            "decision_sha256" => String.duplicate("a", 64),
            "idempotency_key" => "key-plan-0007"
          },
          binding: broken
        )

      assert result["error"]["code"] == "provider_unavailable"
    end

    defmodule BrokenWorkpadAdapter do
      @moduledoc false
      def get_workpad(_issue_id, _opts), do: {:error, :provider_unavailable, %{reason: "down"}}
    end

    test "refuses a report that is not an object" do
      result = run("engineering_report", %{"idempotency_key" => "k", "expected_revision" => 0, "report" => "nope"})

      assert result["error"]["code"] == "invalid_arguments"
    end

    test "binds no workspace and so refuses to import anything" do
      base = tool_binding()
      project = Map.put(base.context.project, :workspace_root, nil)
      broken = Map.put(base, :context, Map.put(base.context, :project, project))

      result =
        run(
          "engineering_blob_import",
          %{
            "relative_path" => "capture.txt",
            "expected_sha256" => String.duplicate("0", 64),
            "media_type" => "text/plain",
            "idempotency_key" => "key-blob-0006"
          },
          binding: broken
        )

      assert result["error"]["code"] == "workspace_root_unknown"
    end
  end

  describe "other entity types" do
    test "records evidence reported by the run" do
      evidence = %{
        "id" => "E-017",
        "project_id" => "embedded-lab-demo",
        "revision" => 1,
        "source_kind" => "serial",
        "title" => "E-017 串口片段",
        "raw" => [],
        "source_refs" => [],
        "binding" => %{},
        "captured_at" => nil,
        "received_at" => "2026-09-14T10:36:02Z",
        "capture_session_id" => "boot-07",
        "derivation_of" => [],
        "limitations" => ["仅有日志片段"],
        "supersedes" => nil,
        "content_status" => "available"
      }

      result = run("engineering_report", report_request("Evidence", evidence))

      assert result["ok"]
      assert result["revision"] == 1

      assert {:ok, record} = Store.get("embedded-lab-demo", "Evidence", "E-017")
      assert record.payload["capture_session_id"] == "boot-07"
      assert record.actor["kind"] == "agent"
    end

    test "a validation report carries its criteria and binding" do
      validation = %{
        "id" => "V-001",
        "project_id" => "embedded-lab-demo",
        "revision" => 1,
        "claim_id" => "claim-buffer-reuse",
        "evidence_ids" => ["E-017"],
        "criteria" => "连续切换 20 次不出现撕裂",
        "criteria_revision" => "c1",
        "binding" => %{"test_profile" => "board_test"},
        "result" => "failed",
        "executed_at" => "2026-09-14T10:36:02Z",
        "command_record_sha256" => nil,
        "limitations" => ["单板单次"]
      }

      assert run("engineering_report", report_request("Validation", validation, %{"idempotency_key" => "key-report-0010"}))["ok"]

      assert {:ok, record} = Store.get("embedded-lab-demo", "Validation", "V-001")
      assert record.payload["result"] == "failed"
    end
  end

  describe "unimplemented tools" do
    test "says so instead of pretending to succeed" do
      for tool <- ["engineering_device_action", "engineering_device_lease"] do
        result = run(tool, %{})

        assert result["error"]["code"] == "unsupported_capability"
        assert result["error"]["details"] =~ tool
        refute result["envelope_success"]
      end
    end

    test "an unknown tool name is reported, not ignored" do
      result = run("engineering_nonsense", %{})

      assert result["error"]["code"] == "unsupported_capability"
    end
  end
end
