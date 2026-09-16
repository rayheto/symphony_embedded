defmodule SymphonyElixir.Experience.Architecture do
  @moduledoc """
  Architecture artifacts for the managed project.

  Generating a diagram is Archify's job and happens outside the workbench. What
  this module owns is the part a host must never take on trust: that the
  delivered files, hashes and pinned skill revision actually agree, that a
  failed generation leaves the previous last-good alone, and that a component's
  status is a projection of engineering records rather than a value the agent
  that drew the picture got to choose.

  Two rules follow from that and are enforced rather than described:

    * a manifest that overstates — `passed` without a validation record behind
      it, or `integrated` where the linked issues say otherwise — is rejected;
    * a manifest may only reference components and relationships that exist in
      the IR delivered with it, so the index can never grow edges the diagram
      does not show.
  """

  require Logger

  alias SymphonyElixir.Experience.{Canonical, Project, Store}

  @schema_version "1.0"
  @required_manifest_fields ~w(schema_version project_id artifact_id kind source_repo_url
     source_revision base_revision plan_revision plan_sources skill_commit ir_sha256 html_sha256
     deliver_receipt_sha256 browser_receipt_sha256 visual_review_sha256 components limitations
     relationships)
  # The Archify revision this build is pinned to; a manifest naming another one
  # was produced by a skill this build has not verified.
  @skill_commit "a07fa1d5b2a10cbea110c5a2be2817397a301cdc"
  @entity_type "ArchitectureArtifact"
  @kinds ~w(source plan delta)
  @layers ~w(L0 L1 L2 L3 L4 crosscutting unclassified)
  @source_ref_kinds ~w(git document blob url)
  @implementation_statuses ~w(planned building integrated)
  @implementation_rank %{"planned" => 0, "building" => 1, "integrated" => 2}
  # Statuses under which a revision is still the workbench's answer for its
  # revision: a request that is queued or running must not be queued again.
  @live_statuses ~w(queued running succeeded)
  @verification_statuses ~w(unverified passed failed stale)
  @media_types %{
    "manifest" => "application/json",
    "ir" => "application/json",
    "html" => "text/html"
  }

  @type artifact :: map()

  # ------------------------------------------------------------------
  # Requests
  # ------------------------------------------------------------------

  @doc """
  Record a request to (re)generate one diagram for one revision.

  A request is a workbench record attached to an existing issue, not a second
  scheduler: generation still happens on the original issue workflow, and this
  call only says which revision was asked for and why it was asked again.

  Repeat requests for the same revision are deduplicated, so a chatty caller or a
  polling loop cannot queue the same diagram twice.
  """
  @spec request(Project.t(), map(), keyword()) :: {:ok, artifact()} | {:error, atom(), map()}
  def request(%Project{} = project, attrs, opts \\ []) do
    with {:ok, kind} <- fetch(attrs, "kind"),
         :ok <- known_kind(kind),
         {:ok, issue_id} <- fetch(attrs, "issue_id"),
         {:ok, scope} <- request_scope(attrs, kind) do
      case find_revision(project, scope, opts) do
        {:ok, existing} ->
          {:ok, existing}

        :none ->
          actor = Keyword.get(opts, :actor, system_actor())

          append_artifact(
            project,
            attrs,
            %{
              "kind" => kind,
              "issue_id" => issue_id,
              "generation_status" => "queued",
              "source_repo_url" => Map.get(attrs, "source_repo_url"),
              "source_revision" => Map.get(scope, "source_revision"),
              "base_revision" => Map.get(attrs, "base_revision"),
              "plan_revision" => Map.get(scope, "plan_revision"),
              "limitations" => request_limitations(attrs, kind),
              "artifact_id" => Map.get(attrs, "artifact_id") || default_artifact_id(project, attrs)
            },
            actor
          )
      end
    end
  end

  # A source or delta diagram is pinned to a commit; a plan diagram is design
  # material and carries no source revision at all.
  defp request_scope(attrs, kind) when kind in ["source", "delta"] do
    case Map.get(attrs, "source_revision") do
      revision when is_binary(revision) ->
        if revision =~ ~r/^[a-f0-9]{40}$/ do
          {:ok, %{"source_revision" => revision}}
        else
          {:error, :invalid_source_revision, %{revision: revision, reason: "源码图必须绑定40位commit"}}
        end

      _missing ->
        {:error, :source_revision_required, %{kind: kind, reason: "源码图没有来源revision就不能声称对应真实源码"}}
    end
  end

  defp request_scope(attrs, "plan") do
    case {Map.get(attrs, "plan_revision"), List.wrap(Map.get(attrs, "plan_sources"))} do
      {revision, sources} when is_binary(revision) and sources != [] ->
        {:ok, %{"plan_revision" => revision}}

      {revision, sources} ->
        {:error, :plan_sources_required, %{plan_revision: revision, plan_sources: sources, reason: "计划图必须写明设计材料来源"}}
    end
  end

  # ------------------------------------------------------------------
  # Publication
  # ------------------------------------------------------------------

  @doc """
  Verify a delivered artifact and, if it holds up, publish it.

  The caller uploads the three files and names their hashes; everything else is
  read back out of the durable store and checked here. Nothing is published on
  the strength of a caller's summary.
  """
  @spec validate_and_publish(Project.t(), map(), keyword()) :: {:ok, artifact()} | {:error, atom(), map()}
  def validate_and_publish(%Project{} = project, attrs, opts \\ []) do
    with {:ok, artifact_id} <- fetch(attrs, "artifact_id"),
         {:ok, manifest_sha} <- fetch(attrs, "manifest_blob_sha256"),
         {:ok, ir_sha} <- fetch(attrs, "ir_blob_sha256"),
         {:ok, html_sha} <- fetch(attrs, "html_blob_sha256"),
         {:ok, manifest} <- read_manifest(project, manifest_sha, opts),
         {:ok, ir} <- read_ir(project, ir_sha, opts),
         {:ok, _html} <- read_html(project, html_sha, opts),
         :ok <- same_artifact(manifest, artifact_id),
         :ok <- same_project(manifest, project),
         :ok <- check_structure(manifest, ir),
         :ok <- check_hashes(manifest, ir_sha, html_sha),
         {:ok, checks} <- check_receipts(project, manifest, opts),
         {:ok, components} <- project_components(project, manifest, opts),
         {:ok, prepared} <-
           prepare(project, attrs, manifest, components, checks, %{
             "ir_sha256" => ir_sha,
             "html_sha256" => html_sha,
             "manifest_sha256" => manifest_sha,
             "artifact_id" => artifact_id
           }),
         {:ok, artifact} <- append_artifact(project, attrs, prepared, actor(opts)) do
      {:ok, artifact}
    else
      {:error, code, details} ->
        record_failure(project, attrs, code, details, actor(opts))
        {:error, code, details}
    end
  end

  # A refusal is a fact the page has to be able to show, so the attempt is kept
  # beside the last-good artifact instead of being logged and forgotten.
  defp record_failure(project, attrs, code, details, actor) do
    case Map.get(attrs, "artifact_id") do
      nil ->
        :ok

      artifact_id ->
        append_artifact(
          project,
          attrs,
          %{
            "artifact_id" => artifact_id,
            "kind" => Map.get(attrs, "kind") || "source",
            "generation_status" => "failed",
            "source_repo_url" => Map.get(attrs, "source_repo_url"),
            "source_revision" => nil,
            "base_revision" => nil,
            "plan_revision" => nil,
            "ir_sha256" => nil,
            "html_sha256" => nil,
            "manifest_sha256" => nil,
            "skill_commit" => @skill_commit,
            # The refusal is the only check this attempt has; the rest never ran.
            "schema_check" => %{"status" => "failed", "receipt_sha256" => nil, "detail" => "#{code}"},
            "browser_check" => %{"status" => "not_run", "receipt_sha256" => nil, "detail" => "生成未通过，未收集浏览器证据"},
            "visual_review" => %{"status" => "not_run", "receipt_sha256" => nil, "detail" => "生成未通过，未做视觉审阅"},
            "last_good_id" => previous_last_good(project),
            "stale" => false,
            "diagnostics" => [%{"code" => to_string(code), "detail" => inspect(details)}],
            "limitations" => ["这次生成未被采纳，仍展示上一版 last-good。"]
          },
          actor
        )
    end

    :ok
  end

  defp prepare(project, attrs, manifest, components, checks, file_shas) do
    previous = previous_last_good(project)

    {:ok,
     %{
       "artifact_id" => file_shas["artifact_id"],
       "kind" => manifest["kind"],
       "generation_status" => "succeeded",
       "source_revision" => manifest["source_revision"],
       "base_revision" => manifest["base_revision"],
       "plan_revision" => manifest["plan_revision"],
       "ir_sha256" => file_shas["ir_sha256"],
       "html_sha256" => file_shas["html_sha256"],
       "manifest_sha256" => file_shas["manifest_sha256"],
       # A successful publication *is* the last-good; the pointer is recorded on
       # the attempt, not in a separate project document that could rot.
       "last_good_id" => file_shas["artifact_id"],
       "previous_last_good_id" => previous,
       "stale" => false,
       "issue_id" => Map.get(attrs, "issue_id"),
       "source_repo_url" => manifest["source_repo_url"],
       "plan_sources" => manifest["plan_sources"],
       "components" => components,
       "schema_check" => checks["schema_check"],
       "browser_check" => checks["browser_check"],
       "visual_review" => checks["visual_review"],
       "limitations" => Enum.uniq(List.wrap(manifest["limitations"]) ++ projection_limitations(manifest, components)),
       "skill_commit" => manifest["skill_commit"]
     }}
  end

  # ------------------------------------------------------------------
  # Reads
  # ------------------------------------------------------------------

  @doc "Every archived revision of one artifact, newest first, or of the whole project."
  @spec list_revisions(Project.t(), String.t() | nil, keyword()) :: [artifact()] | {:error, atom(), map()}
  def list_revisions(%Project{} = project, artifact_id \\ nil, opts \\ []) do
    case store_read(fn -> Store.list_revisions(project.project_id, @entity_type, server_opts(project, opts)) end) do
      {:error, code, details} ->
        {:error, code, details}

      records ->
        records
        |> Enum.map(&wire/1)
        |> Enum.filter(&(is_nil(artifact_id) or &1["id"] == artifact_id))
        |> Enum.reverse()
    end
  end

  @doc "The newest published artifact for the project, if any generation ever succeeded."
  @spec last_good(Project.t(), keyword()) :: {:ok, artifact()} | {:error, atom(), map()}
  def last_good(%Project{} = project, opts \\ []) do
    case list_revisions(project, nil, opts) do
      {:error, code, details} ->
        {:error, code, details}

      revisions ->
        case Enum.find(revisions, &(&1["generation_status"] == "succeeded")) do
          nil -> {:error, :no_last_good, %{project_id: project.project_id}}
          artifact -> {:ok, artifact}
        end
    end
  end

  @doc "One artifact revision, newest revision when no revision is named."
  @spec get(Project.t(), String.t(), pos_integer() | nil, keyword()) :: {:ok, artifact()} | {:error, atom(), map()}
  def get(%Project{} = project, artifact_id, revision \\ nil, opts \\ []) do
    result =
      case revision do
        nil ->
          store_read(fn -> Store.get(project.project_id, @entity_type, artifact_id, server_opts(project, opts)) end)

        revision ->
          store_read(fn ->
            Store.get_revision(project.project_id, @entity_type, artifact_id, revision, server_opts(project, opts))
          end)
      end

    case result do
      {:ok, record} -> {:ok, wire(record)}
      {:error, _code, _details} -> {:error, :artifact_not_found, %{artifact_id: artifact_id, revision: revision}}
    end
  end

  @doc """
  The stored manifest for an artifact, read back from the content-addressed
  store so the component index can never drift from the bytes that were checked.
  """
  @spec manifest(Project.t(), artifact(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def manifest(%Project{} = project, artifact, opts \\ []) do
    with {:ok, sha} <- fetch(artifact, "manifest_sha256"),
         {:ok, bytes} <- read_blob(project, sha, opts) do
      decode_json(bytes, :manifest_invalid)
    end
  end

  @doc """
  The component index as the page shows it: the delivered manifest's components
  with their statuses projected from records, and only the relationships the IR
  actually has.
  """
  @spec component_index(Project.t(), artifact(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def component_index(%Project{} = project, artifact, opts \\ []) do
    with {:ok, decoded} <- manifest(project, artifact, opts) do
      # The stored components carry the *projected* statuses; the manifest blob is
      # what was checked, so it supplies the relationships the page navigates.
      components = List.wrap(artifact["components"])

      {:ok,
       %{
         "components" => Enum.map(components, &component_view(&1, artifact)),
         "relationships" => Enum.map(decoded["relationships"] || [], &relationship_view/1),
         "limitations" => artifact["limitations"] || decoded["limitations"] || [],
         "source_repo_url" => artifact["source_repo_url"] || decoded["source_repo_url"],
         "source_revision" => artifact["source_revision"] || decoded["source_revision"],
         "plan_revision" => artifact["plan_revision"] || decoded["plan_revision"]
       }}
    end
  end

  @doc """
  Whether an artifact still describes the revision the host is working on.

  Unknown is a real answer: without a recorded run binding there is nothing to
  compare against, and "we cannot tell" must not be rendered as "fresh".
  """
  @spec staleness(Project.t(), artifact(), keyword()) :: :fresh | :stale | :unknown
  def staleness(%Project{} = project, artifact, opts \\ []) do
    recorded = artifact["source_revision"]

    # A plan diagram names no source revision, so there is nothing a working
    # revision could be compared against.
    if is_binary(recorded) do
      case current_revision(project, opts) do
        {:ok, revision} when revision == recorded -> :fresh
        {:ok, _other} -> :stale
        {:error, _code, _details} -> :unknown
      end
    else
      :unknown
    end
  end

  @doc "The last commit the host recorded for this project, if it ever recorded one."
  @spec current_revision(Project.t(), keyword()) :: {:ok, String.t()} | {:error, atom(), map()}
  def current_revision(%Project{} = project, opts \\ []) do
    case store_read(fn -> Store.list(project.project_id, "Binding", server_opts(project, opts)) end) do
      {:error, code, details} ->
        {:error, code, details}

      [] ->
        {:error, :no_binding, %{project_id: project.project_id}}

      bindings ->
        case bindings |> List.last() |> Map.get(:payload, %{}) |> Map.get("repo_revision") do
          revision when is_binary(revision) -> {:ok, revision}
          _absent -> {:error, :no_binding, %{project_id: project.project_id}}
        end
    end
  end

  @doc """
  How the viewer is allowed to be embedded.

  The diagram is hosted in a sandboxed frame on a controlled endpoint that hands
  out the artifact bytes and nothing else: no same-origin access, no application
  cookies, and no pretence that the upstream viewer has a host event API.
  """
  @spec viewer_descriptor(Project.t(), artifact(), keyword()) :: map()
  def viewer_descriptor(%Project{} = project, artifact, _opts \\ []) do
    base = "/workbench/architecture/#{artifact["id"]}"

    %{
      "artifact_id" => artifact["id"],
      "revision" => artifact["revision"],
      "embed_url" => "#{base}/artifact/html?theme=light",
      "standalone_url" => "#{base}/artifact/html?theme=light&standalone=1",
      "manifest_url" => "#{base}/artifact/manifest",
      "sandbox" => "allow-scripts allow-downloads",
      "allow_same_origin" => false,
      "project_id" => project.project_id,
      "limitations" => [
        "图内呈现保持 Archify 原样；宿主不注入样式，也不依赖未声明的 iframe 事件协议。"
      ]
    }
  end

  @doc "Read one delivered file back by kind (`manifest`, `ir`, `html`)."
  @spec read_file(Project.t(), artifact(), String.t(), keyword()) ::
          {:ok, binary(), String.t()} | {:error, atom(), map()}
  def read_file(%Project{} = project, artifact, kind, opts \\ []) do
    case sha_field(kind) do
      nil ->
        {:error, :unknown_artifact_kind, %{kind: kind, supported: Map.keys(@media_types)}}

      field ->
        with {:ok, sha} <- fetch(artifact, field),
             {:ok, bytes} <- read_blob(project, sha, opts) do
          {:ok, bytes, Map.fetch!(@media_types, kind)}
        end
    end
  end

  defp sha_field("manifest"), do: "manifest_sha256"
  defp sha_field("ir"), do: "ir_sha256"
  defp sha_field("html"), do: "html_sha256"
  defp sha_field(_kind), do: nil

  @doc "The Archify revision this build accepts manifests from."
  @spec skill_commit() :: String.t()
  def skill_commit, do: @skill_commit

  # ------------------------------------------------------------------
  # Verification
  # ------------------------------------------------------------------

  defp read_manifest(project, sha, opts) do
    with {:ok, bytes} <- read_blob(project, sha, opts) do
      decode_json(bytes, :manifest_invalid)
    end
  end

  # The IR has to be readable as the diagram the manifest claims to index; an
  # HTML file, or a truncated upload, is not evidence of a diagram.
  defp read_ir(project, sha, opts) do
    with {:ok, bytes} <- read_blob(project, sha, opts),
         {:ok, decoded} <- decode_json(bytes, :ir_invalid) do
      case {decoded["components"], decoded["connections"]} do
        {components, connections} when is_list(components) and is_list(connections) -> {:ok, decoded}
        _other -> {:error, :ir_invalid, %{reason: "均不支持：IR 必须带 components 与 connections 数组"}}
      end
    end
  end

  defp read_html(project, sha, opts) do
    with {:ok, bytes} <- read_blob(project, sha, opts) do
      if String.contains?(String.slice(bytes, 0, 4_096), "<html") or String.contains?(bytes, "<svg") do
        {:ok, bytes}
      else
        {:error, :html_invalid, %{reason: "delivered HTML 不像一个自包含的图"}}
      end
    end
  end

  defp same_artifact(%{"artifact_id" => claimed}, artifact_id) when claimed == artifact_id, do: :ok

  defp same_artifact(manifest, artifact_id) do
    {:error, :artifact_id_mismatch, %{manifest: Map.get(manifest, "artifact_id"), requested: artifact_id}}
  end

  # A diagram of another project must not become this project's diagram.
  defp same_project(%{"project_id" => claimed}, %Project{project_id: claimed}), do: :ok

  defp same_project(manifest, project) do
    {:error, :project_id_mismatch, %{manifest: Map.get(manifest, "project_id"), project: project.project_id}}
  end

  defp check_structure(manifest, ir) do
    with :ok <- check_required(manifest),
         :ok <- check_schema_version(manifest),
         :ok <- check_skill(manifest),
         :ok <- check_kind_fields(manifest),
         :ok <- check_components(manifest, ir) do
      check_relationships(manifest, ir)
    end
  end

  defp check_required(manifest) do
    missing = Enum.reject(@required_manifest_fields, &Map.has_key?(manifest, &1))
    unknown = Map.keys(manifest) -- @required_manifest_fields

    cond do
      missing != [] -> {:error, :manifest_incomplete, %{missing: missing}}
      unknown != [] -> {:error, :manifest_unknown_field, %{fields: unknown}}
      true -> :ok
    end
  end

  defp check_schema_version(%{"schema_version" => @schema_version}), do: :ok

  defp check_schema_version(manifest) do
    {:error, :unsupported_manifest_version, %{schema_version: Map.get(manifest, "schema_version"), supported: @schema_version}}
  end

  defp check_skill(%{"skill_commit" => @skill_commit}), do: :ok

  defp check_skill(manifest) do
    {:error, :unpinned_skill_commit, %{skill_commit: Map.get(manifest, "skill_commit"), pinned: @skill_commit, reason: "manifest 由未固定版本的 skill 生成"}}
  end

  defp check_kind_fields(%{"kind" => "source"} = manifest) do
    if revision?(manifest["source_revision"]) do
      :ok
    else
      {:error, :source_revision_required, %{source_revision: manifest["source_revision"]}}
    end
  end

  defp check_kind_fields(%{"kind" => "delta"} = manifest) do
    if revision?(manifest["source_revision"]) and revision?(manifest["base_revision"]) do
      :ok
    else
      {:error, :delta_revisions_required, %{source_revision: manifest["source_revision"], base_revision: manifest["base_revision"]}}
    end
  end

  defp check_kind_fields(%{"kind" => "plan"} = manifest) do
    cond do
      not is_binary(manifest["plan_revision"]) or manifest["plan_revision"] == "" ->
        {:error, :plan_revision_required, %{plan_revision: manifest["plan_revision"]}}

      List.wrap(manifest["plan_sources"]) == [] ->
        {:error, :plan_sources_required, %{reason: "计划图必须写明设计材料来源"}}

      manifest["source_revision"] != nil ->
        {:error, :plan_claims_source_revision, %{source_revision: manifest["source_revision"], reason: "计划图是设计材料，不能声称绑定源码 revision"}}

      true ->
        :ok
    end
  end

  defp check_kind_fields(manifest) do
    {:error, :unknown_artifact_kind, %{kind: Map.get(manifest, "kind"), supported: @kinds}}
  end

  defp revision?(value), do: is_binary(value) and value =~ ~r/^[a-f0-9]{40}$/

  # Components are the IR's components. An index that names a node the picture
  # does not contain would be a second, invisible architecture.
  defp check_components(manifest, ir) do
    ids = Enum.map(ir["components"] || [], &Map.get(&1, "id"))
    claimed = manifest["components"]

    if not is_list(claimed) or claimed == [] do
      {:error, :components_required, %{reason: "manifest 必须索引真实存在的组件"}}
    else
      with :ok <- check_component_shapes(claimed),
           :ok <- check_known_ids(claimed, ids) do
        check_source_refs(claimed, manifest)
      end
    end
  end

  defp check_component_shapes(components) do
    Enum.reduce_while(components, :ok, fn component, :ok ->
      case component_shape(component) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp component_shape(%{} = component) do
    id = Map.get(component, "id")

    case component_identity(component) do
      :ok -> component_statuses(component, id)
      error -> error
    end
  end

  defp component_shape(component), do: {:error, :component_invalid, %{component: component, reason: "组件必须是对象"}}

  defp component_identity(component) do
    id = Map.get(component, "id")
    layers = Map.get(component, "layers")

    cond do
      not is_binary(id) or id == "" ->
        {:error, :component_invalid, %{component: component, reason: "组件必须有 id"}}

      not is_binary(Map.get(component, "label")) ->
        {:error, :component_invalid, %{id: id, reason: "组件必须有 label"}}

      not is_list(layers) or layers -- @layers != [] ->
        {:error, :unknown_layer, %{id: id, layers: layers, supported: @layers}}

      not is_list(Map.get(component, "source_refs")) ->
        {:error, :component_invalid, %{id: id, reason: "组件必须有 source_refs 列表"}}

      true ->
        :ok
    end
  end

  defp component_statuses(component, id) do
    cond do
      Map.get(component, "implementation_status") not in @implementation_statuses ->
        {:error, :unknown_implementation_status, %{id: id, value: Map.get(component, "implementation_status")}}

      Map.get(component, "verification_status") not in @verification_statuses ->
        {:error, :unknown_verification_status, %{id: id, value: Map.get(component, "verification_status")}}

      true ->
        check_linked_ids(component)
    end
  end

  defp check_linked_ids(component) do
    Enum.reduce_while(~w(issue_ids problem_case_ids evidence_ids), :ok, fn key, :ok ->
      if is_list(Map.get(component, key)) do
        {:cont, :ok}
      else
        {:halt, {:error, :component_invalid, %{id: component["id"], reason: "#{key} 必须是列表"}}}
      end
    end)
  end

  defp check_known_ids(components, ir_ids) do
    unknown = Enum.map(components, & &1["id"]) -- ir_ids

    if unknown == [] do
      :ok
    else
      {:error, :unknown_component_id, %{ids: unknown, reason: "manifest 索引了 IR 里不存在的组件"}}
    end
  end

  # A source reference is only checkable against the revision the artifact
  # claims, so every git reference is held to the artifact's own revision.
  defp check_source_refs(components, manifest) do
    Enum.reduce_while(components, :ok, fn component, :ok ->
      case source_refs_ok(component["source_refs"], manifest) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp source_refs_ok(refs, manifest) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case source_ref_ok(ref, manifest) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp source_ref_ok(%{} = ref, manifest) do
    kind = Map.get(ref, "kind")
    locator = Map.get(ref, "locator")

    with :ok <- source_ref_shape(kind, locator, ref) do
      git_ref_matches_artifact(kind, ref, manifest)
    end
  end

  defp source_ref_ok(ref, _manifest), do: {:error, :source_ref_invalid, %{ref: ref, reason: "来源必须是对象"}}

  defp source_ref_shape(kind, locator, ref) do
    cond do
      kind not in @source_ref_kinds ->
        {:error, :unknown_source_ref_kind, %{kind: kind, supported: @source_ref_kinds}}

      not is_binary(locator) or locator == "" ->
        {:error, :source_ref_invalid, %{ref: ref, reason: "来源必须有 locator"}}

      true ->
        :ok
    end
  end

  # Only a git reference claims a commit, so only a git reference is held to the
  # artifact's own revision.
  defp git_ref_matches_artifact("git", ref, manifest) do
    revision = Map.get(ref, "repo_revision")
    locator = Map.get(ref, "locator")

    cond do
      revision == nil ->
        :ok

      manifest["kind"] == "plan" ->
        {:error, :plan_cites_commit, %{locator: locator, repo_revision: revision, reason: "设计材料不能声称绑定已核验的 commit"}}

      revision == manifest["source_revision"] ->
        :ok

      true ->
        {:error, :source_ref_revision_mismatch, mismatch(locator, revision, manifest)}
    end
  end

  defp git_ref_matches_artifact(_kind, _ref, _manifest), do: :ok

  defp mismatch(locator, revision, manifest) do
    %{locator: locator, ref_revision: revision, artifact_revision: manifest["source_revision"]}
  end

  defp check_relationships(manifest, ir) do
    ids = Enum.map(ir["components"] || [], &Map.get(&1, "id"))
    connections = Map.new(ir["connections"] || [], &{Map.get(&1, "id"), &1})

    Enum.reduce_while(manifest["relationships"] || [], :ok, fn relationship, :ok ->
      case relationship_ok(relationship, ids, connections) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp relationship_ok(%{} = relationship, ids, connections) do
    id = Map.get(relationship, "id")
    from = Map.get(relationship, "from_component_id")
    to = Map.get(relationship, "to_component_id")

    cond do
      not is_binary(id) or id == "" ->
        {:error, :relationship_invalid, %{relationship: relationship, reason: "关系必须有 id"}}

      from not in ids or to not in ids ->
        {:error, :unknown_relationship_endpoint, %{id: id, from: from, to: to}}

      not is_binary(Map.get(relationship, "description")) ->
        {:error, :relationship_invalid, %{id: id, reason: "关系必须有 description"}}

      not Map.has_key?(connections, id) ->
        {:error, :unknown_relationship_id, %{id: id, reason: "关系必须来自随图交付的 IR"}}

      true ->
        matches_connection(Map.fetch!(connections, id), relationship)
    end
  end

  defp relationship_ok(relationship, _ids, _connections) do
    {:error, :relationship_invalid, %{relationship: relationship, reason: "关系必须是对象"}}
  end

  # The index may describe a connection, never redefine it.
  defp matches_connection(connection, relationship) do
    if connection["from"] == relationship["from_component_id"] and connection["to"] == relationship["to_component_id"] do
      :ok
    else
      {:error, :relationship_mismatch, %{id: relationship["id"], ir: %{from: connection["from"], to: connection["to"]}}}
    end
  end

  defp check_hashes(manifest, ir_sha, html_sha) do
    cond do
      manifest["ir_sha256"] != ir_sha ->
        {:error, :ir_hash_mismatch, %{manifest: manifest["ir_sha256"], delivered: ir_sha}}

      manifest["html_sha256"] != html_sha ->
        {:error, :html_hash_mismatch, %{manifest: manifest["html_sha256"], delivered: html_sha}}

      true ->
        :ok
    end
  end

  # Only the deliver receipt is a gate: it is the deterministic acceptance of the
  # artifact. Browser evidence has its own truthful status and, as upstream
  # states, an environmental failure there does not invalidate a delivery — so it
  # is recorded and shown, not used to reject the artifact.
  defp check_receipts(project, manifest, opts) do
    with {:ok, deliver} <- read_receipt(project, manifest, "deliver_receipt_sha256", opts),
         :ok <- deliverables_met(deliver),
         {:ok, browser} <- read_receipt(project, manifest, "browser_receipt_sha256", opts),
         {:ok, visual} <- read_receipt(project, manifest, "visual_review_sha256", opts) do
      {:ok,
       %{
         "schema_check" => %{"status" => "passed", "receipt_sha256" => nil, "detail" => "manifest 与 IR、哈希、固定 skill 版本一致"},
         "browser_check" => browser_check(browser),
         "visual_review" => visual_check(visual)
       }}
    end
  end

  defp read_receipt(project, manifest, field, opts) do
    case Map.get(manifest, field) do
      nil ->
        {:ok, nil}

      sha ->
        case read_blob(project, sha, opts) do
          {:ok, bytes} -> {:ok, %{"sha256" => sha, "receipt" => decode_receipt(bytes)}}
          {:error, _code, _details} -> {:error, :receipt_missing, %{field: field, sha256: sha}}
        end
    end
  end

  defp decode_receipt(bytes) do
    case Canonical.decode(bytes) do
      {:ok, %{} = decoded} -> decoded
      _other -> nil
    end
  end

  # "A non-zero exit can never be described as success", and a showcase pass is
  # all nine artifact checks with no composition error or warning.
  defp deliverables_met(nil), do: {:error, :deliver_receipt_missing, %{reason: "没有 deliver 回执就不能声称交付成功"}}

  defp deliverables_met(%{"receipt" => receipt}) when is_map(receipt) do
    validation = receipt["validation"] || %{}

    cond do
      receipt["ok"] != true ->
        {:error, :deliver_not_successful, %{ok: receipt["ok"]}}

      validation["compositionStatus"] not in ["pass", "passed"] ->
        {:error, :deliver_composition_failed, %{validation: validation}}

      validation["errors"] != 0 or validation["warnings"] != 0 ->
        {:error, :deliver_diagnostics_present, %{validation: validation}}

      validation["checksPassed"] != validation["checkCount"] ->
        {:error, :deliver_checks_incomplete, %{validation: validation}}

      true ->
        :ok
    end
  end

  defp deliverables_met(_receipt), do: {:error, :deliver_receipt_unreadable, %{}}

  defp browser_check(nil) do
    %{"status" => "not_run", "receipt_sha256" => nil, "detail" => "没有浏览器证据回执"}
  end

  defp browser_check(%{"sha256" => sha, "receipt" => receipt}) when is_map(receipt) do
    %{
      "status" => browser_status(receipt["status"]),
      "receipt_sha256" => sha,
      "detail" => receipt["error"] || "visual-check 状态：#{inspect(receipt["status"])}"
    }
  end

  defp browser_check(%{"sha256" => sha}) do
    %{"status" => "not_run", "receipt_sha256" => sha, "detail" => "浏览器回执无法解析"}
  end

  # Upstream's own vocabulary: exit 0/pass, exit 1/fail, exit 2/skipped. An
  # unrecognised status is not promoted to a pass.
  defp browser_status("pass"), do: "passed"
  defp browser_status("fail"), do: "failed"
  defp browser_status("skipped"), do: "skipped"
  defp browser_status(_other), do: "not_run"

  defp visual_check(nil) do
    %{"status" => "not_run", "receipt_sha256" => nil, "detail" => "尚无独立视觉审阅记录"}
  end

  defp visual_check(%{"sha256" => sha, "receipt" => receipt}) when is_map(receipt) do
    %{
      "status" => visual_status(receipt["visual_review"]),
      "receipt_sha256" => sha,
      "detail" => Map.get(receipt, "detail") || "独立视觉审阅记录已归档"
    }
  end

  defp visual_check(%{"sha256" => sha}) do
    %{"status" => "not_run", "receipt_sha256" => sha, "detail" => "视觉审阅回执无法解析"}
  end

  # A review is still pending until a reader actually looked at the artifact.
  defp visual_status("passed"), do: "passed"
  defp visual_status("failed"), do: "failed"
  defp visual_status(_pending), do: "not_run"

  # ------------------------------------------------------------------
  # Projection: status comes from records, not from the drawing
  # ------------------------------------------------------------------

  defp project_components(project, manifest, opts) do
    Enum.reduce_while(manifest["components"] || [], {:ok, []}, fn component, {:ok, acc} ->
      case project_component(project, component, manifest, opts) do
        {:ok, projected} -> {:cont, {:ok, acc ++ [projected]}}
        {:error, code, details} -> {:halt, {:error, code, details}}
      end
    end)
  end

  defp project_component(project, component, manifest, opts) do
    with {:ok, implementation} <- projected_implementation(project, component, opts),
         {:ok, verification} <- projected_verification(project, component, manifest, opts) do
      {:ok,
       component
       |> Map.put("implementation_status", implementation)
       |> Map.put("verification_status", verification)}
    end
  end

  # Overstatement is refused rather than corrected: a diagram that says
  # "integrated" with nothing behind it must not become a published artifact
  # that merely looks slightly different from what its author asked for.
  defp projected_implementation(project, component, opts) do
    # An unreadable projection is not `planned`: reporting a component as
    # planned because the store was down would be a fabricated answer.
    with {:ok, states} <- issue_states(project, component["issue_ids"], opts) do
      derived = derive_implementation(states)
      claimed = component["implementation_status"]

      if rank(claimed) > rank(derived) do
        {:error, :implementation_overstated, %{id: component["id"], claimed: claimed, derived: derived}}
      else
        {:ok, derived}
      end
    end
  end

  # Stages are ordered, so "further along than the records support" is one
  # comparison instead of a rule per pair.
  defp rank(status), do: Map.fetch!(@implementation_rank, status)

  defp derive_implementation([]), do: "planned"

  defp derive_implementation(states) do
    cond do
      Enum.all?(states, &(&1 == "terminal")) -> "integrated"
      Enum.any?(states, &(&1 == "active")) -> "building"
      true -> "planned"
    end
  end

  defp projected_verification(project, component, manifest, opts) do
    case validations_for(project, component["evidence_ids"], opts) do
      {:error, code, details} ->
        {:error, code, details}

      {:ok, []} ->
        backed(component, "unverified", "没有找到与该组件关联的验证记录")

      {:ok, validations} ->
        from_validations(component, validations, manifest)
    end
  end

  defp from_validations(component, validations, manifest) do
    results = Enum.map(validations, &Map.get(&1, "result"))

    cond do
      "passed" in results ->
        if Enum.any?(validations, &passed_at_revision?(&1, manifest["source_revision"])) do
          backed(component, "passed", "有通过的验证记录")
        else
          backed(component, "stale", "验证记录来自其他 revision")
        end

      "failed" in results ->
        backed(component, "failed", "验证记录显示失败")

      Enum.any?(results, &(&1 in ["stale", "inconclusive"])) ->
        backed(component, "stale", "验证记录不足以支持通过")

      true ->
        backed(component, "unverified", "验证记录尚未给出结论")
    end
  end

  defp passed_at_revision?(validation, nil), do: validation["result"] == "passed"

  defp passed_at_revision?(validation, revision) do
    case get_in(validation, ["binding", "repo_revision"]) do
      ^revision -> true
      _other -> false
    end
  end

  defp backed(component, derived, detail) do
    claimed = component["verification_status"]

    cond do
      claimed == derived ->
        {:ok, derived}

      claimed == "passed" ->
        {:error, :verification_overstated, %{id: component["id"], claimed: claimed, derived: derived, detail: detail}}

      true ->
        {:ok, derived}
    end
  end

  # ------------------------------------------------------------------
  # Records behind the projection
  # ------------------------------------------------------------------

  # Provider state decides implementation: a component is only integrated when
  # every issue that owns it has actually reached a terminal state.
  defp issue_states(project, issue_ids, opts) do
    issue_ids = List.wrap(issue_ids)

    Enum.reduce_while(issue_ids, {:ok, []}, fn issue_id, {:ok, acc} ->
      case issue_state(project, issue_id, opts) do
        {:ok, state} -> {:cont, {:ok, acc ++ [state]}}
        {:error, code, details} -> {:halt, {:error, code, details}}
      end
    end)
  end

  defp issue_state(project, issue_id, opts) do
    case store_read(fn -> Store.get(project.project_id, "Issue", issue_id, server_opts(project, opts)) end) do
      {:ok, record} -> {:ok, classify_state(record.payload, project)}
      {:error, _code, _details} -> {:error, :issue_not_found, %{issue_id: issue_id}}
    end
  end

  defp classify_state(payload, project) do
    state = payload["state"] || payload["status"]

    cond do
      state in terminal_states(project) -> "terminal"
      state in active_states(project) -> "active"
      true -> "pending"
    end
  end

  defp terminal_states(project) do
    Map.get(project.tracker_settings || %{}, :terminal_states) || Map.get(project.tracker_settings || %{}, "terminal_states") || []
  end

  defp active_states(project) do
    Map.get(project.tracker_settings || %{}, :active_states) || Map.get(project.tracker_settings || %{}, "active_states") || []
  end

  defp validations_for(project, evidence_ids, opts) do
    evidence_ids = List.wrap(evidence_ids)

    if evidence_ids == [], do: {:ok, []}, else: list_validations(project, evidence_ids, opts)
  end

  defp list_validations(project, evidence_ids, opts) do
    case store_read(fn -> Store.list(project.project_id, "Validation", server_opts(project, opts)) end) do
      {:error, code, details} -> {:error, code, details}
      records -> {:ok, Enum.filter(Enum.map(records, & &1.payload), &cites_any?(&1, evidence_ids))}
    end
  end

  defp cites_any?(validation, evidence_ids) do
    cited = List.wrap(validation["evidence_ids"])
    cited -- evidence_ids != cited
  end

  # ------------------------------------------------------------------
  # Records
  # ------------------------------------------------------------------

  defp append_artifact(project, attrs, payload, actor) do
    artifact_id = payload["artifact_id"]
    expected = expected_revision(project, artifact_id, attrs)

    case store_read(fn ->
           Store.append(
             project.project_id,
             @entity_type,
             artifact_id,
             expected,
             payload,
             actor,
             server_opts(project, []) ++ [idempotency_key: Map.get(attrs, "idempotency_key")]
           )
         end) do
      {:ok, record} -> {:ok, wire(record)}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp expected_revision(project, artifact_id, attrs) do
    case Map.get(attrs, "expected_revision") do
      revision when is_integer(revision) ->
        revision

      _absent ->
        current_revision_of(project, artifact_id)
    end
  end

  defp current_revision_of(project, artifact_id) do
    case store_read(fn -> Store.get(project.project_id, @entity_type, artifact_id, server_opts(project, [])) end) do
      {:ok, record} -> record.entity_revision
      {:error, _code, _details} -> 0
    end
  end

  defp previous_last_good(project) do
    case last_good(project) do
      {:ok, artifact} -> artifact["id"]
      {:error, _code, _details} -> nil
    end
  end

  @spec wire(map()) :: artifact()
  defp wire(record) do
    record.payload
    |> Map.put("id", record.entity_id)
    |> Map.put("revision", record.entity_revision)
    |> Map.put("recorded_at", record.recorded_at)
  end

  defp component_view(component, artifact) do
    component
    |> Map.put("source_revision", artifact["source_revision"])
    |> Map.put("links", %{
      "issues" => Enum.map(List.wrap(component["issue_ids"]), &issue_link/1),
      "problem_cases" => Enum.map(List.wrap(component["problem_case_ids"]), &problem_case_link/1),
      "evidence" => Enum.map(List.wrap(component["evidence_ids"]), &evidence_link/1)
    })
  end

  # Only the issue route is a page this build actually serves; the rest are shown
  # as identifiers so the sidebar never offers a link that goes nowhere.
  defp issue_link(id), do: %{"id" => id, "href" => "/workbench/issues/#{id}"}
  defp problem_case_link(id), do: %{"id" => id, "href" => nil}
  defp evidence_link(id), do: %{"id" => id, "href" => nil}

  defp relationship_view(relationship) do
    relationship
    |> Map.put("source", "ir")
    |> Map.put("href", nil)
  end

  defp projection_limitations(manifest, components) do
    # Only the components the caller claimed a *better* status for are worth a
    # line: the rest agree with the records and need no apology.
    overstated =
      (manifest["components"] || [])
      |> Enum.zip(components)
      |> Enum.reject(fn {claimed, projected} ->
        {claimed["implementation_status"], claimed["verification_status"]} ==
          {projected["implementation_status"], projected["verification_status"]}
      end)
      |> Enum.map(fn {claimed, projected} ->
        "#{claimed["id"]}：索引原写为 #{claimed["implementation_status"]}/#{claimed["verification_status"]}，" <>
          "按记录判定为 #{projected["implementation_status"]}/#{projected["verification_status"]}"
      end)

    if overstated == [] do
      []
    else
      ["组件状态以工程记录为准：" | overstated]
    end
  end

  defp request_limitations(attrs, "plan") do
    ["计划图是设计材料，来源为 #{Enum.join(List.wrap(Map.get(attrs, "plan_sources")), "、")}，尚未对应真实源码 revision。"]
  end

  defp request_limitations(_attrs, _kind), do: []

  defp default_artifact_id(project, attrs) do
    "#{project.project_id}-#{Map.get(attrs, "kind")}-#{System.unique_integer([:positive])}"
  end

  defp find_revision(project, scope, opts) do
    case list_revisions(project, nil, opts) do
      {:error, _code, _details} -> :none
      revisions -> existing_attempt(revisions, Map.get(scope, "source_revision") || Map.get(scope, "plan_revision"))
    end
  end

  defp existing_attempt(revisions, wanted) do
    case Enum.find(revisions, &(&1["generation_status"] in @live_statuses and (&1["source_revision"] || &1["plan_revision"]) == wanted)) do
      nil -> :none
      found -> {:ok, found}
    end
  end

  # ------------------------------------------------------------------
  # Plumbing
  # ------------------------------------------------------------------

  # A store that is not running is a degraded read, not a broken page: the caller
  # is told the records are unavailable instead of being handed an empty project.
  defp store_read(fun) do
    fun.()
  catch
    :exit, reason -> {:error, :store_unavailable, %{reason: inspect(reason)}}
  end

  defp read_blob(project, sha, opts) do
    store_read(fn -> Store.get_blob(project.project_id, sha, server_opts(project, opts)) end)
  end

  defp decode_json(bytes, code) do
    case Canonical.decode(bytes) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, code, %{reason: "顶层必须是对象"}}
      {:error, reason} -> {:error, code, %{reason: inspect(reason)}}
    end
  end

  defp server_opts(project, opts), do: [server: project.store] ++ Keyword.take(opts, [:actor])

  defp actor(opts), do: Keyword.get(opts, :actor, system_actor())

  # The publisher is the host verifying a delivery: not a human verdict and not
  # the agent that drew the picture, which is why it is recorded as a system
  # actor unless a caller names its own.
  defp system_actor do
    %{kind: "system", id: "architecture-publisher", display_name: "架构发布"}
  end

  defp known_kind(kind) when kind in @kinds, do: :ok
  defp known_kind(kind), do: {:error, :unknown_artifact_kind, %{kind: kind, supported: @kinds}}

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> {:error, :invalid_arguments, %{missing: key}}
      value -> {:ok, value}
    end
  end

  defp fetch(_map, key), do: {:error, :invalid_arguments, %{missing: key}}
end
