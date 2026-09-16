defmodule SymphonyElixir.Experience.ArchitectureTest do
  # The publisher reads back every file it was handed, so the store is real and
  # the tests are synchronous: a fixture that published in one process must be
  # visible to the reader in another.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Experience.{Architecture, Canonical, Project, Store}

  @project_id "embedded-lab-demo"
  @revision "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"
  @actor %{kind: "human", id: "local-operator", display_name: "本机操作者"}
  @html "<html><body><svg></svg></body></html>"

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-arch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")

    # `restart: :transient` lets one test stop the store deliberately without the
    # supervisor putting it straight back.
    start_supervised!(%{
      id: store,
      start: {Store, :start_link, [[name: store, data_root: root]]},
      restart: :transient
    })

    on_exit(fn -> File.rm_rf(root) end)

    %{store: store, root: root}
  end

  defp project(context) do
    %Project{
      project_id: @project_id,
      mode: "demo",
      adapter: SymphonyElixir.Experience.DemoAdapter,
      store: context.store,
      display_states: ["待办", "进行中", "已完成"],
      workspace_root: "/tmp/workspaces",
      tracker_settings: %{active_states: ["Todo", "In Progress"], terminal_states: ["Done", "Closed"]}
    }
  end

  defp ir(overrides \\ %{}) do
    Map.merge(
      %{
        "components" => [
          %{"id" => "core", "type" => "backend", "label" => "Core"},
          %{"id" => "storage", "type" => "database", "label" => "Storage"}
        ],
        "connections" => [%{"id" => "rel_core_storage", "from" => "core", "to" => "storage"}]
      },
      overrides
    )
  end

  defp deliver_receipt(overrides \\ %{}) do
    Map.merge(
      %{
        "ok" => true,
        "validation" => %{
          "checksPassed" => 9,
          "checkCount" => 9,
          "compositionStatus" => "pass",
          "errors" => 0,
          "warnings" => 0
        }
      },
      overrides
    )
  end

  defp component(overrides \\ %{}) do
    Map.merge(
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
      },
      overrides
    )
  end

  defp manifest(_context, files, overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "project_id" => @project_id,
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
        "browser_receipt_sha256" => nil,
        "visual_review_sha256" => nil,
        "components" => [component()],
        "limitations" => [],
        "relationships" => [
          %{
            "id" => "rel_core_storage",
            "from_component_id" => "core",
            "to_component_id" => "storage",
            "description" => "core 写入 storage",
            "source_refs" => []
          }
        ]
      },
      overrides
    )
    |> drop_marked(overrides)
  end

  # `:drop` removes a key entirely, which is how a manifest that omits a
  # required field is built; `nil` would still be present.
  defp drop_marked(built, overrides) do
    Enum.reduce(overrides, built, fn {key, value}, acc ->
      if value == :drop, do: Map.delete(acc, key), else: acc
    end)
  end

  # The three uploaded files and their manifest, for tests that need to name
  # their own publication arguments.
  defp uploaded(context, overrides \\ %{}) do
    ir_sha = put(context, Canonical.encode!(ir()), "application/json")
    html_sha = put(context, @html, "text/html")
    deliver_sha = put(context, Canonical.encode!(deliver_receipt()), "application/json")

    files = %{"ir" => ir_sha, "html" => html_sha, "deliver" => deliver_sha}
    manifest_sha = put(context, Canonical.encode!(manifest(context, files, overrides)), "application/json")

    %{"ir" => ir_sha, "html" => html_sha, "manifest" => manifest_sha}
  end

  defp publish_attrs(files, extra) do
    Map.merge(
      %{
        "artifact_id" => "art-1",
        "manifest_blob_sha256" => files["manifest"],
        "ir_blob_sha256" => files["ir"],
        "html_blob_sha256" => files["html"]
      },
      extra
    )
  end

  defp put(context, bytes, media_type) do
    {:ok, receipt} = Store.put_blob(@project_id, bytes, media_type, server: context.store)
    receipt["sha256"]
  end

  # Publishes through the same path an agent uses: three blobs and their hashes.
  defp publish(context, overrides \\ %{}, upload_overrides \\ %{}, target \\ nil) do
    ir_sha = put(context, Canonical.encode!(Map.merge(ir(), Map.get(upload_overrides, :ir, %{}))), "application/json")
    html_sha = put(context, Map.get(upload_overrides, :html, @html), "text/html")

    deliver_sha =
      put(context, Canonical.encode!(Map.get(upload_overrides, :deliver, deliver_receipt())), "application/json")

    files = %{"ir" => ir_sha, "html" => html_sha, "deliver" => deliver_sha}

    browser_sha =
      case Map.get(upload_overrides, :browser) do
        nil -> nil
        receipt -> put(context, Canonical.encode!(receipt), "application/json")
      end

    visual_sha =
      case Map.get(upload_overrides, :visual) do
        nil -> nil
        receipt -> put(context, Canonical.encode!(receipt), "application/json")
      end

    built =
      manifest(context, files, overrides)
      |> Map.put("browser_receipt_sha256", browser_sha)
      |> Map.put("visual_review_sha256", visual_sha)

    manifest_sha = put(context, Canonical.encode!(built), "application/json")

    Architecture.validate_and_publish(target || project(context), %{
      "artifact_id" => built["artifact_id"],
      "manifest_blob_sha256" => manifest_sha,
      "ir_blob_sha256" => ir_sha,
      "html_blob_sha256" => html_sha,
      "issue_id" => Map.get(overrides, "issue_id")
    })
  end

  defp issue(context, id, state) do
    {:ok, _record} =
      Store.append(@project_id, "Issue", id, 0, %{"id" => id, "state" => state}, @actor, server: context.store)

    :ok
  end

  defp validation(context, id, evidence_ids, result, revision \\ @revision) do
    payload = %{
      "id" => id,
      "evidence_ids" => evidence_ids,
      "result" => result,
      "binding" => %{"repo_revision" => revision}
    }

    {:ok, _record} = Store.append(@project_id, "Validation", id, 0, payload, @actor, server: context.store)
    :ok
  end

  defp binding(context, revision) do
    {:ok, _record} =
      Store.append(@project_id, "Binding", "run-1", 0, %{"repo_revision" => revision}, @actor, server: context.store)

    :ok
  end

  describe "requests" do
    test "records a source request only with a real commit", context do
      assert {:ok, artifact} =
               Architecture.request(project(context), %{
                 "kind" => "source",
                 "issue_id" => "demo-issue-1",
                 "source_revision" => @revision
               })

      assert artifact["generation_status"] == "queued"
      assert artifact["source_revision"] == @revision
      assert artifact["kind"] == "source"
    end

    test "refuses a source request with no revision or a malformed one", context do
      assert {:error, :source_revision_required, %{}} =
               Architecture.request(project(context), %{"kind" => "source", "issue_id" => "demo-issue-1"})

      assert {:error, :invalid_source_revision, %{revision: "HEAD"}} =
               Architecture.request(project(context), %{
                 "kind" => "source",
                 "issue_id" => "demo-issue-1",
                 "source_revision" => "HEAD"
               })
    end

    test "a plan request names its design material and claims no source revision", context do
      assert {:ok, artifact} =
               Architecture.request(project(context), %{
                 "kind" => "plan",
                 "issue_id" => "demo-issue-1",
                 "plan_revision" => "plan-r7",
                 "plan_sources" => ["docs/implementation/SPEC.md"]
               })

      assert artifact["plan_revision"] == "plan-r7"
      assert artifact["source_revision"] == nil
      assert Enum.any?(artifact["limitations"], &String.contains?(&1, "设计材料"))
    end

    test "refuses a plan request without sources", context do
      assert {:error, :plan_sources_required, %{plan_revision: "plan-r7"}} =
               Architecture.request(project(context), %{
                 "kind" => "plan",
                 "issue_id" => "demo-issue-1",
                 "plan_revision" => "plan-r7"
               })
    end

    test "refuses an issue-less or unknown-kind request", context do
      assert {:error, :invalid_arguments, %{missing: "issue_id"}} =
               Architecture.request(project(context), %{"kind" => "source", "source_revision" => @revision})

      assert {:error, :unknown_artifact_kind, %{kind: "poster"}} =
               Architecture.request(project(context), %{
                 "kind" => "poster",
                 "issue_id" => "demo-issue-1",
                 "source_revision" => @revision
               })
    end

    test "the same revision is not requested twice", context do
      attrs = %{"kind" => "source", "issue_id" => "demo-issue-1", "source_revision" => @revision, "artifact_id" => "art-1"}

      assert {:ok, first} = Architecture.request(project(context), attrs)
      assert {:ok, second} = Architecture.request(project(context), attrs)
      assert first["id"] == second["id"]
      assert length(Architecture.list_revisions(project(context))) == 1
    end
  end

  describe "publication" do
    test "publishes a verified delivery and projects the component status", context do
      assert {:ok, artifact} = publish(context)

      assert artifact["generation_status"] == "succeeded"
      assert artifact["last_good_id"] == "art-1"
      assert artifact["skill_commit"] == Architecture.skill_commit()
      assert artifact["schema_check"]["status"] == "passed"
      assert artifact["browser_check"]["status"] == "not_run"
      assert artifact["visual_review"]["status"] == "not_run"

      assert {:ok, good} = Architecture.last_good(project(context))
      assert good["id"] == "art-1"
    end

    test "keeps the delivered files readable by hash", context do
      {:ok, artifact} = publish(context)
      project = project(context)

      assert {:ok, bytes, "text/html"} = Architecture.read_file(project, artifact, "html")
      assert bytes == @html

      assert {:ok, ir_bytes, "application/json"} = Architecture.read_file(project, artifact, "ir")
      assert ir_bytes =~ "rel_core_storage"
      assert {:ok, decoded} = Architecture.manifest(project, artifact)
      assert decoded["artifact_id"] == "art-1"

      assert {:ok, index} = Architecture.component_index(project, artifact)
      assert [%{"id" => "core"}] = index["components"]
      assert [%{"id" => "rel_core_storage", "source" => "ir"}] = index["relationships"]
    end

    test "records a failed browser check without failing the delivery", context do
      browser = %{"status" => "fail", "error" => "Page.loadEventFired: event timed out"}
      assert {:ok, artifact} = publish(context, %{}, %{browser: browser})

      assert artifact["browser_check"]["status"] == "failed"
      assert artifact["browser_check"]["detail"] =~ "timed out"
      assert artifact["browser_check"]["receipt_sha256"]
      assert artifact["generation_status"] == "succeeded"
    end

    test "records a skipped browser check as skipped, never as a pass", context do
      assert {:ok, artifact} = publish(context, %{}, %{browser: %{"status" => "skipped"}})
      assert artifact["browser_check"]["status"] == "skipped"
    end

    test "records an independent visual review separately from the browser run", context do
      visual = %{"visual_review" => "passed", "detail" => "人工读图：主链清晰"}
      assert {:ok, artifact} = publish(context, %{}, %{visual: visual})
      assert artifact["visual_review"]["status"] == "passed"
      assert artifact["browser_check"]["status"] == "not_run"
    end

    test "an unrecognised browser status is not promoted", context do
      assert {:ok, artifact} = publish(context, %{}, %{browser: %{"status" => "maybe"}})
      assert artifact["browser_check"]["status"] == "not_run"
    end

    test "a refused publication is kept beside the last-good", context do
      {:ok, _good} = publish(context)

      assert {:error, :unknown_component_id, %{ids: ["ghost"]}} =
               publish(context, %{"components" => [component(%{"id" => "ghost"})]})

      revisions = Architecture.list_revisions(project(context))
      assert [failed, good] = revisions
      assert failed["generation_status"] == "failed"
      assert [%{"code" => "unknown_component_id"}] = failed["diagnostics"]
      assert good["generation_status"] == "succeeded"
      assert {:ok, still} = Architecture.last_good(project(context))
      assert still["id"] == "art-1"
    end

    test "a failure with no artifact id is not recorded as an attempt", context do
      assert {:error, :invalid_arguments, %{missing: "artifact_id"}} =
               Architecture.validate_and_publish(project(context), %{})

      assert Architecture.list_revisions(project(context)) == []
    end
  end

  describe "refusals" do
    test "refuses an incomplete manifest", context do
      assert {:error, :manifest_incomplete, %{missing: ["limitations"]}} =
               publish(context, %{"limitations" => :drop})
    end

    test "refuses a manifest that invents fields of its own", context do
      assert {:error, :manifest_unknown_field, %{fields: ["layer_ids"]}} = publish(context, %{"layer_ids" => ["L0"]})
    end

    test "refuses another schema version or an unpinned skill", context do
      assert {:error, :unsupported_manifest_version, %{supported: "1.0"}} = publish(context, %{"schema_version" => "2.0"})

      assert {:error, :unpinned_skill_commit, %{}} =
               publish(context, %{"skill_commit" => String.duplicate("b", 40)})
    end

    test "refuses a manifest that names a different artifact", context do
      ir_sha = put(context, Canonical.encode!(ir()), "application/json")
      html_sha = put(context, @html, "text/html")
      deliver_sha = put(context, Canonical.encode!(deliver_receipt()), "application/json")
      manifest_sha = put(context, Canonical.encode!(manifest(context, %{"ir" => ir_sha, "html" => html_sha, "deliver" => deliver_sha})), "application/json")

      assert {:error, :artifact_id_mismatch, %{manifest: "art-1", requested: "art-2"}} =
               Architecture.validate_and_publish(project(context), %{
                 "artifact_id" => "art-2",
                 "manifest_blob_sha256" => manifest_sha,
                 "ir_blob_sha256" => ir_sha,
                 "html_blob_sha256" => html_sha
               })
    end

    test "refuses components the IR does not contain", context do
      assert {:error, :unknown_component_id, %{ids: ["ghost"]}} =
               publish(context, %{"components" => [component(%{"id" => "ghost"})]})

      assert {:error, :components_required, %{}} = publish(context, %{"components" => []})
    end

    test "refuses a component whose shape is not usable", context do
      assert {:error, :component_invalid, %{reason: "组件必须有 id"}} =
               publish(context, %{"components" => [component(%{"id" => ""})]})

      assert {:error, :component_invalid, %{reason: "组件必须有 label"}} =
               publish(context, %{"components" => [component(%{"label" => nil})]})

      assert {:error, :unknown_layer, %{supported: _}} = publish(context, %{"components" => [component(%{"layers" => ["L9"]})]})

      assert {:error, :unknown_implementation_status, %{}} =
               publish(context, %{"components" => [component(%{"implementation_status" => "shipped"})]})

      assert {:error, :unknown_verification_status, %{}} =
               publish(context, %{"components" => [component(%{"verification_status" => "green"})]})

      assert {:error, :component_invalid, %{reason: "组件必须有 source_refs 列表"}} =
               publish(context, %{"components" => [component(%{"source_refs" => nil})]})

      assert {:error, :component_invalid, %{reason: "issue_ids 必须是列表"}} =
               publish(context, %{"components" => [component(%{"issue_ids" => nil})]})

      assert {:error, :component_invalid, %{reason: "组件必须是对象"}} = publish(context, %{"components" => ["core"]})
    end

    test "refuses a source reference that cannot be checked against the revision", context do
      bad_ref = [%{"kind" => "git", "locator" => "a.ex", "repo_revision" => String.duplicate("c", 40), "line" => nil, "end_line" => nil}]

      assert {:error, :source_ref_revision_mismatch, %{artifact_revision: @revision}} =
               publish(context, %{"components" => [component(%{"source_refs" => bad_ref})]})

      assert {:error, :unknown_source_ref_kind, %{kind: "jira"}} =
               publish(context, %{
                 "components" => [component(%{"source_refs" => [%{"kind" => "jira", "locator" => "x", "repo_revision" => nil}]})]
               })

      assert {:error, :source_ref_invalid, %{reason: "来源必须有 locator"}} =
               publish(context, %{
                 "components" => [
                   component(%{"source_refs" => [%{"kind" => "document", "locator" => "", "repo_revision" => nil}]})
                 ]
               })

      assert {:error, :source_ref_invalid, %{reason: "来源必须是对象"}} =
               publish(context, %{"components" => [component(%{"source_refs" => ["a.ex"]})]})
    end

    test "a source reference that is not a commit is accepted as it is", context do
      document = [%{"kind" => "document", "locator" => "docs/SPEC.md", "repo_revision" => nil, "line" => nil, "end_line" => nil}]

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"source_refs" => document})]})
      assert [%{"source_refs" => [%{"kind" => "document"}]}] = artifact["components"]
    end

    test "a plan diagram may point at a path but may not claim a commit", context do
      plan = %{
        "kind" => "plan",
        "source_revision" => nil,
        "plan_revision" => "plan-r7",
        "plan_sources" => ["docs/implementation/SPEC.md"]
      }

      path_ref = [%{"kind" => "git", "locator" => "a.ex", "repo_revision" => nil, "line" => nil, "end_line" => nil}]

      assert {:ok, artifact} =
               publish(context, Map.put(plan, "components", [component(%{"source_refs" => path_ref})]))

      assert artifact["kind"] == "plan"

      cited_ref = [%{"kind" => "git", "locator" => "a.ex", "repo_revision" => @revision, "line" => nil, "end_line" => nil}]

      assert {:error, :plan_cites_commit, %{repo_revision: @revision}} =
               publish(context, Map.put(plan, "components", [component(%{"source_refs" => cited_ref})]))
    end

    test "refuses relationships the IR does not have", context do
      assert {:error, :unknown_relationship_id, %{id: "rel_invented"}} =
               publish(context, %{
                 "relationships" => [
                   %{
                     "id" => "rel_invented",
                     "from_component_id" => "core",
                     "to_component_id" => "storage",
                     "description" => "凭空多出的边",
                     "source_refs" => []
                   }
                 ]
               })

      assert {:error, :unknown_relationship_endpoint, %{to: "ghost"}} =
               publish(context, %{
                 "relationships" => [
                   %{
                     "id" => "rel_core_storage",
                     "from_component_id" => "core",
                     "to_component_id" => "ghost",
                     "description" => "端点不存在",
                     "source_refs" => []
                   }
                 ]
               })

      assert {:error, :relationship_mismatch, %{ir: %{from: "core", to: "storage"}}} =
               publish(context, %{
                 "relationships" => [
                   %{
                     "id" => "rel_core_storage",
                     "from_component_id" => "storage",
                     "to_component_id" => "core",
                     "description" => "方向与 IR 相反",
                     "source_refs" => []
                   }
                 ]
               })

      assert {:error, :relationship_invalid, %{reason: "关系必须有 id"}} =
               publish(context, %{
                 "relationships" => [
                   %{
                     "id" => "",
                     "from_component_id" => "core",
                     "to_component_id" => "storage",
                     "description" => "无 id",
                     "source_refs" => []
                   }
                 ]
               })

      assert {:error, :relationship_invalid, %{reason: "关系必须有 description"}} =
               publish(context, %{
                 "relationships" => [
                   %{
                     "id" => "rel_core_storage",
                     "from_component_id" => "core",
                     "to_component_id" => "storage",
                     "description" => nil,
                     "source_refs" => []
                   }
                 ]
               })

      assert {:error, :relationship_invalid, %{reason: "关系必须是对象"}} = publish(context, %{"relationships" => ["rel"]})
    end

    test "refuses a plan that claims a source revision", context do
      assert {:error, :plan_claims_source_revision, %{}} =
               publish(context, %{"kind" => "plan", "plan_revision" => "r7", "plan_sources" => ["SPEC.md"]})

      assert {:error, :plan_revision_required, %{}} =
               publish(context, %{
                 "kind" => "plan",
                 "source_revision" => nil,
                 "plan_revision" => nil,
                 "plan_sources" => ["SPEC.md"]
               })

      assert {:error, :plan_sources_required, %{}} =
               publish(context, %{"kind" => "plan", "source_revision" => nil, "plan_revision" => "r7", "plan_sources" => []})
    end

    test "refuses a delta with only one revision", context do
      assert {:error, :delta_revisions_required, %{base_revision: nil}} = publish(context, %{"kind" => "delta"})
    end

    test "refuses an unknown kind", context do
      assert {:error, :unknown_artifact_kind, %{kind: "poster"}} = publish(context, %{"kind" => "poster"})
    end

    test "refuses a manifest whose hashes do not match the delivered bytes", context do
      assert {:error, :ir_hash_mismatch, %{}} = publish(context, %{"ir_sha256" => String.duplicate("a", 64)})
      assert {:error, :html_hash_mismatch, %{}} = publish(context, %{"html_sha256" => String.duplicate("a", 64)})
    end

    test "refuses a receipt that is not in the store", context do
      assert {:error, :receipt_missing, %{field: "deliver_receipt_sha256"}} =
               publish(context, %{"deliver_receipt_sha256" => String.duplicate("a", 64)})
    end

    test "refuses a delivery that did not pass every check", context do
      assert {:error, :deliver_not_successful, %{ok: false}} =
               publish(context, %{}, %{deliver: deliver_receipt(%{"ok" => false})})

      assert {:error, :deliver_composition_failed, %{}} =
               publish(context, %{}, %{deliver: deliver_receipt(%{"validation" => %{"compositionStatus" => "fail"}})})

      assert {:error, :deliver_diagnostics_present, %{}} =
               publish(context, %{}, %{
                 deliver: deliver_receipt(%{"validation" => %{"compositionStatus" => "pass", "errors" => 0, "warnings" => 2}})
               })

      assert {:error, :deliver_checks_incomplete, %{}} =
               publish(context, %{}, %{
                 deliver:
                   deliver_receipt(%{
                     "validation" => %{"compositionStatus" => "pass", "errors" => 0, "warnings" => 0, "checksPassed" => 4}
                   })
               })
    end

    test "refuses bytes that are not the files the manifest describes", context do
      assert {:error, :ir_invalid, %{reason: _}} =
               publish(context, %{}, %{ir: %{"connections" => nil}})

      assert {:error, :html_invalid, %{reason: _}} = publish(context, %{}, %{html: "not a diagram"})

      assert {:error, :manifest_invalid, %{reason: _}} = publish_manifest_text(context, "not json")
    end

    test "refuses a deliver receipt that is not readable json", context do
      assert {:error, :deliver_receipt_unreadable, %{}} = publish(context, %{}, %{deliver: "not a receipt"})
    end
  end

  # A manifest that is not even JSON cannot be decoded into a hash-match check.
  defp publish_manifest_text(context, text) do
    ir_sha = put(context, Canonical.encode!(ir()), "application/json")
    html_sha = put(context, @html, "text/html")
    _deliver_sha = put(context, Canonical.encode!(deliver_receipt()), "application/json")
    manifest_sha = put(context, text, "application/json")

    Architecture.validate_and_publish(project(context), %{
      "artifact_id" => "art-1",
      "manifest_blob_sha256" => manifest_sha,
      "ir_blob_sha256" => ir_sha,
      "html_blob_sha256" => html_sha
    })
  end

  describe "projection" do
    test "an unlinked component stays planned and unverified", context do
      {:ok, artifact} = publish(context)
      assert [%{"implementation_status" => "planned", "verification_status" => "unverified"}] = artifact["components"]
    end

    test "implementation follows the linked issues, not the claim", context do
      issue(context, "demo-issue-1", "In Progress")
      issue(context, "demo-issue-2", "Done")

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-1", "demo-issue-2"]})]})
      assert [%{"implementation_status" => "building"}] = artifact["components"]

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-2"]})]})
      assert [%{"implementation_status" => "integrated"}] = artifact["components"]
    end

    test "refuses a component that claims to be further along than it is", context do
      issue(context, "demo-issue-1", "Todo")
      issue(context, "demo-issue-2", "Backlog")

      assert {:error, :implementation_overstated, %{claimed: "integrated", derived: "building"}} =
               publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-1"], "implementation_status" => "integrated"})]})

      assert {:error, :implementation_overstated, %{claimed: "building", derived: "planned"}} =
               publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-2"], "implementation_status" => "building"})]})
    end

    test "a claimed but unbacked pass is refused", context do
      assert {:error, :verification_overstated, %{claimed: "passed", derived: "unverified"}} =
               publish(context, %{"components" => [component(%{"verification_status" => "passed"})]})
    end

    test "verification follows the validation records", context do
      validation(context, "val-1", ["E-1"], "passed")

      assert {:ok, artifact} =
               publish(context, %{"components" => [component(%{"evidence_ids" => ["E-1"], "verification_status" => "passed"})]})

      assert [%{"verification_status" => "passed"}] = artifact["components"]
    end

    test "a pass from another revision is stale, not passed", context do
      validation(context, "val-1", ["E-1"], "passed", String.duplicate("d", 40))

      assert {:error, :verification_overstated, %{derived: "stale"}} =
               publish(context, %{"components" => [component(%{"evidence_ids" => ["E-1"], "verification_status" => "passed"})]})
    end

    test "a failed or inconclusive validation is not a pass", context do
      validation(context, "val-1", ["E-1"], "failed")

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"evidence_ids" => ["E-1"]})]})
      assert [%{"verification_status" => "failed"}] = artifact["components"]

      validation(context, "val-2", ["E-2"], "inconclusive")

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"evidence_ids" => ["E-2"]})]})
      assert [%{"verification_status" => "stale"}] = artifact["components"]
    end

    test "an understated component is projected up and recorded as a limitation", context do
      issue(context, "demo-issue-1", "Done")

      assert {:ok, artifact} =
               publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-1"], "implementation_status" => "planned"})]})

      assert [%{"implementation_status" => "integrated"}] = artifact["components"]
      assert Enum.any?(artifact["limitations"], &String.contains?(&1, "组件状态以工程记录为准"))
    end

    test "an unreadable projection is an error, not a quiet downgrade", context do
      assert {:error, :issue_not_found, %{issue_id: "demo-issue-1"}} =
               publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-1"]})]})
    end

    test "a stopping store is reported instead of inventing statuses", context do
      ir_sha = put(context, Canonical.encode!(ir()), "application/json")
      html_sha = put(context, @html, "text/html")
      deliver_sha = put(context, Canonical.encode!(deliver_receipt()), "application/json")

      manifest_sha =
        put(
          context,
          Canonical.encode!(manifest(context, %{"ir" => ir_sha, "html" => html_sha, "deliver" => deliver_sha})),
          "application/json"
        )

      :ok = stop_supervised!(context.store)

      assert {:error, :store_unavailable, %{}} =
               Architecture.validate_and_publish(project(context), %{
                 "artifact_id" => "art-1",
                 "manifest_blob_sha256" => manifest_sha,
                 "ir_blob_sha256" => ir_sha,
                 "html_blob_sha256" => html_sha
               })
    end
  end

  describe "reads" do
    test "staleness is unknown without a recorded revision", context do
      {:ok, artifact} = publish(context)
      project = project(context)

      assert Architecture.staleness(project, artifact) == :unknown
      assert {:error, :no_binding, %{}} = Architecture.current_revision(project)
    end

    test "staleness follows the recorded working revision", context do
      {:ok, artifact} = publish(context)
      project = project(context)

      binding(context, @revision)
      assert Architecture.staleness(project, artifact) == :fresh

      {:ok, _record} =
        Store.append(@project_id, "Binding", "run-2", 0, %{"repo_revision" => String.duplicate("e", 40)}, @actor, server: context.store)

      assert Architecture.staleness(project, artifact) == :stale
    end

    test "a binding without a revision is not a revision", context do
      {:ok, _record} = Store.append(@project_id, "Binding", "run-1", 0, %{"note" => "no revision"}, @actor, server: context.store)
      assert {:error, :no_binding, %{}} = Architecture.current_revision(project(context))
    end

    test "a plan artifact has no revision to be stale against", context do
      {:ok, artifact} =
        Architecture.request(project(context), %{
          "kind" => "plan",
          "issue_id" => "demo-issue-1",
          "plan_revision" => "plan-r7",
          "plan_sources" => ["SPEC.md"],
          "artifact_id" => "art-plan"
        })

      assert Architecture.staleness(project(context), artifact) == :unknown
    end

    test "one artifact revision can be read back by number", context do
      {:ok, _artifact} = publish(context)
      project = project(context)

      assert {:ok, first} = Architecture.get(project, "art-1", 1)
      assert first["revision"] == 1
      assert {:ok, newest} = Architecture.get(project, "art-1")
      assert newest["revision"] == 1
      assert {:error, :artifact_not_found, %{}} = Architecture.get(project, "art-1", 9)
    end

    test "no last-good is reported as such", context do
      assert {:error, :no_last_good, %{project_id: @project_id}} = Architecture.last_good(project(context))
    end

    test "an unreadable store surfaces as an error rather than an empty project", context do
      project = project(struct!(project(context), store: Module.concat(__MODULE__, :Missing)))
      assert {:error, :store_unavailable, %{}} = Architecture.list_revisions(project)
      assert {:error, :store_unavailable, %{}} = Architecture.last_good(project)
    end

    test "the viewer descriptor keeps the frame away from the application origin", context do
      {:ok, artifact} = publish(context)
      descriptor = Architecture.viewer_descriptor(project(context), artifact)

      assert descriptor["sandbox"] == "allow-scripts allow-downloads"
      assert descriptor["allow_same_origin"] == false
      assert descriptor["embed_url"] =~ "theme=light"
      assert descriptor["standalone_url"] =~ "standalone=1"
      assert descriptor["manifest_url"] =~ "/artifact/manifest"
    end

    test "a component index carries links only where a page exists", context do
      issue(context, "demo-issue-1", "Todo")

      {:ok, artifact} =
        publish(context, %{
          "components" => [component(%{"issue_ids" => ["demo-issue-1"], "evidence_ids" => ["E-1"], "problem_case_ids" => ["C-1"]})]
        })

      {:ok, index} = Architecture.component_index(project(context), artifact)
      [component] = index["components"]

      assert component["links"]["issues"] == [%{"id" => "demo-issue-1", "href" => "/workbench/issues/demo-issue-1"}]
      assert component["links"]["evidence"] == [%{"id" => "E-1", "href" => nil}]
      assert component["links"]["problem_cases"] == [%{"id" => "C-1", "href" => nil}]
      assert component["source_revision"] == @revision
    end

    test "an artifact whose manifest is gone cannot be indexed", context do
      {:ok, _artifact} = publish(context)
      project = project(context)
      {:ok, artifact} = Architecture.get(project, "art-1")

      File.rm_rf!(Path.join([Store.data_root(context.store), "blobs"]))

      assert {:error, :blob_missing, %{}} = Architecture.manifest(project, artifact)
      assert {:error, :blob_missing, %{}} = Architecture.component_index(project, artifact)
      assert {:error, :blob_missing, %{}} = Architecture.read_file(project, artifact, "ir")
    end
  end

  describe "degradation" do
    # A project whose journal cannot be opened at all is a degraded read: the
    # caller is told, and no status is invented from an empty answer.
    @broken "broken-project"

    defp broken_project(context) do
      File.mkdir_p!(Path.join([context.root, "projects", @broken, "records.jsonl"]))
      struct!(project(context), project_id: @broken)
    end

    defp broken_overrides do
      %{"project_id" => @broken, "components" => [component(%{"evidence_ids" => ["E-1"]})]}
    end

    test "an unreadable project is reported instead of read as empty", context do
      broken = broken_project(context)

      assert {:error, :journal_unreadable, %{reason: :eisdir}} = Architecture.list_revisions(broken)
      assert {:error, :journal_unreadable, %{}} = Architecture.last_good(broken)
      assert {:error, :journal_unreadable, %{}} = Architecture.current_revision(broken)

      # A request cannot be deduplicated against a project it cannot read, so it
      # is attempted rather than silently reported as already queued.
      assert {:error, :journal_unreadable, %{}} =
               Architecture.request(broken, request_attrs())
    end

    test "a component whose validations cannot be read is not called unverified", context do
      broken = broken_project(context)

      assert {:error, :journal_unreadable, %{}} = publish(context, broken_overrides(), %{}, broken)
    end

    test "a manifest for another project is not published into this one", context do
      assert {:error, :project_id_mismatch, %{manifest: "other-project"}} =
               publish(context, %{"project_id" => "other-project"})
    end
  end

  defp request_attrs do
    %{"kind" => "source", "issue_id" => "demo-issue-1", "source_revision" => @revision}
  end

  describe "edges" do
    test "a revision with no delivered manifest has no component index", context do
      {:ok, queued} = Architecture.request(project(context), request_attrs())

      assert {:error, :invalid_arguments, %{missing: "manifest_sha256"}} =
               Architecture.component_index(project(context), queued)
    end

    test "the delivered manifest is readable as a file", context do
      {:ok, artifact} = publish(context)
      assert {:ok, bytes, "application/json"} = Architecture.read_file(project(context), artifact, "manifest")
      assert bytes =~ "art-1"
      assert {:error, :unknown_artifact_kind, %{kind: "poster"}} = Architecture.read_file(project(context), artifact, "poster")
    end

    test "a source artifact must name a revision", context do
      assert {:error, :source_revision_required, %{source_revision: nil}} =
               publish(context, %{"source_revision" => nil})
    end

    test "a published artifact must carry a deliver receipt", context do
      assert {:error, :deliver_receipt_missing, %{reason: _}} = publish(context, %{"deliver_receipt_sha256" => nil})
    end

    test "a browser receipt is recorded as a pass only when it says so", context do
      {:ok, artifact} = publish(context, %{}, %{browser: %{"status" => "pass"}})
      assert artifact["browser_check"]["status"] == "passed"
      assert artifact["browser_check"]["detail"] =~ "pass"
    end

    test "a receipt blob that is not an object is not read as a status", context do
      assert {:ok, artifact} = publish(context, %{}, %{browser: "not a receipt", visual: "not a receipt"})
      assert artifact["browser_check"]["status"] == "not_run"
      assert artifact["browser_check"]["detail"] == "浏览器回执无法解析"
      assert artifact["visual_review"]["status"] == "not_run"
      assert artifact["visual_review"]["detail"] == "视觉审阅回执无法解析"
    end

    test "a failed visual review is recorded as failed", context do
      {:ok, artifact} = publish(context, %{}, %{visual: %{"visual_review" => "failed", "detail" => "主链被卡片遮住"}})
      assert artifact["visual_review"]["status"] == "failed"
      assert artifact["visual_review"]["detail"] == "主链被卡片遮住"

      {:ok, pending} = publish(context, %{"artifact_id" => "art-2"}, %{visual: %{"visual_review" => "pending"}})
      assert pending["visual_review"]["status"] == "not_run"
    end

    test "a component that already claims the projected status is kept", context do
      issue(context, "demo-issue-1", "Todo")

      assert {:ok, artifact} =
               publish(context, %{"components" => [component(%{"issue_ids" => ["demo-issue-1"], "implementation_status" => "building"})]})

      assert [%{"implementation_status" => "building"}] = artifact["components"]
      assert artifact["limitations"] == []
    end

    test "a validation without a conclusion stays unverified", context do
      validation(context, "val-1", ["E-1"], "unverified")

      assert {:ok, artifact} = publish(context, %{"components" => [component(%{"evidence_ids" => ["E-1"]})]})
      assert [%{"verification_status" => "unverified"}] = artifact["components"]
    end

    test "design material is judged by its validations, not by a revision it lacks", context do
      validation(context, "val-1", ["E-1"], "passed")

      plan = %{
        "kind" => "plan",
        "source_revision" => nil,
        "plan_revision" => "plan-r7",
        "plan_sources" => ["docs/implementation/SPEC.md"],
        "components" => [component(%{"source_refs" => [], "evidence_ids" => ["E-1"], "verification_status" => "passed"})]
      }

      assert {:ok, artifact} = publish(context, plan)
      assert [%{"verification_status" => "passed"}] = artifact["components"]
    end

    test "an explicitly expected revision is honoured", context do
      project = project(context)

      assert {:ok, first} =
               Architecture.validate_and_publish(project, publish_attrs(uploaded(context), %{"expected_revision" => 0}))

      assert first["revision"] == 1

      conflict = uploaded(context)

      assert {:error, :revision_conflict, %{expected: 0, current: 1}} =
               Architecture.validate_and_publish(project, publish_attrs(conflict, %{"expected_revision" => 0}))

      assert {:ok, second} =
               Architecture.validate_and_publish(project, publish_attrs(conflict, %{"expected_revision" => 1}))

      assert second["revision"] == 2
    end

    test "a manifest that decodes to a list is not a manifest", context do
      ir_sha = put(context, Canonical.encode!(ir()), "application/json")
      html_sha = put(context, @html, "text/html")
      manifest_sha = put(context, "[]", "application/json")

      assert {:error, :manifest_invalid, %{reason: "顶层必须是对象"}} =
               Architecture.validate_and_publish(project(context), %{
                 "artifact_id" => "art-1",
                 "manifest_blob_sha256" => manifest_sha,
                 "ir_blob_sha256" => ir_sha,
                 "html_blob_sha256" => html_sha
               })
    end

    test "a request that is not a map is refused", context do
      assert {:error, :invalid_arguments, %{missing: "kind"}} = Architecture.request(project(context), "not-a-map")
    end
  end

  describe "the delivered platform diagram" do
    # The one artifact this repository actually delivered is republished here
    # through the same verifier an agent's upload goes through, so the checked-in
    # bytes are held to the rules rather than to a description of them.
    @delivered Path.expand("../../../../docs/architecture/symphony-embedded-workbench", __DIR__)

    test "is accepted by this build's verifier", context do
      files =
        for name <- ~w(source.architecture.json architecture.html deliver.receipt.json browser.receipt.json manifest.json),
            into: %{},
            do: {name, File.read!(Path.join(@delivered, name))}

      manifest_sha = put(context, files["manifest.json"], "application/json")
      ir_sha = put(context, files["source.architecture.json"], "application/json")
      html_sha = put(context, files["architecture.html"], "text/html")
      browser_sha = put(context, files["browser.receipt.json"], "application/json")
      deliver_sha = put(context, files["deliver.receipt.json"], "application/json")

      assert is_binary(browser_sha)
      assert is_binary(deliver_sha)

      project = struct!(project(context), project_id: "symphony-embedded-workbench")

      assert {:ok, artifact} =
               Architecture.validate_and_publish(project, %{
                 "artifact_id" => "symphony-embedded-workbench-source",
                 "manifest_blob_sha256" => manifest_sha,
                 "ir_blob_sha256" => ir_sha,
                 "html_blob_sha256" => html_sha
               })

      assert artifact["generation_status"] == "succeeded"
      assert artifact["schema_check"]["status"] == "passed"
      assert artifact["source_revision"] == "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"

      # The delivery is what was accepted; the browser run is a separate claim
      # that failed here and is kept as failed.
      assert artifact["browser_check"]["status"] == "failed"
      assert artifact["browser_check"]["detail"] =~ "timed out"

      # Every source reference is held to the revision the artifact names.
      assert length(artifact["components"]) == 10
      assert Enum.all?(artifact["components"], &(&1["layers"] == ["unclassified"]))
      assert Enum.all?(artifact["components"], &source_refs_pinned?(&1["source_refs"], artifact["source_revision"]))

      # The embedded profile describes the managed product, so the host diagram
      # claims no layer and says so.
      assert Enum.any?(artifact["limitations"], &String.contains?(&1, "unclassified"))

      assert {:ok, index} = Architecture.component_index(project, artifact)
      assert length(index["relationships"]) == 10
      assert index["components"] |> Enum.map(& &1["id"]) |> Enum.member?("orchestrator")
    end

    defp source_refs_pinned?([], _revision), do: true

    defp source_refs_pinned?(refs, revision) do
      Enum.all?(refs, &(&1["kind"] == "git" and &1["repo_revision"] == revision))
    end
  end
end
