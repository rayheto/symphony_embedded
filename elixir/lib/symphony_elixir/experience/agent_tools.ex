defmodule SymphonyElixir.Experience.AgentTools do
  @moduledoc """
  Structured engineering tools exposed to Codex app-server turns.

  These are *additive*: the provider-native tools (`linear_graphql` and the
  original workpad policy) stay exactly as they were, and nothing here reaches
  the scheduler. A report is bound to the run that made it, so a machine can
  never produce a human verdict, and every write is a compare-and-swap on the
  durable record rather than an in-place edit.
  """

  require Logger

  alias SymphonyElixir.Devices.Manager
  alias SymphonyElixir.Experience.{Architecture, Canonical, Project, Store}
  alias SymphonyElixir.PathSafety

  @contract "agent-tools.json"
  @agent_entity_types ~w(ProblemCase Evidence Validation Decision)
  @max_blob_bytes 67_108_864

  @doc """
  The tool specs to advertise plus the scope they are bound to.

  Returns no tools when the workbench is off, so a repository that never opted
  in sees exactly the tool surface it had before.
  """
  @spec bind(keyword()) :: %{tool_specs: [map()], context: map() | nil}
  def bind(opts \\ []) do
    case Project.load() do
      {:ok, project} -> %{tool_specs: tool_specs(), context: context(project, opts)}
      {:error, _code, _details} -> %{tool_specs: [], context: nil}
    end
  end

  @doc "The canonical tool list with `#/$defs` resolved into the app-server format."
  @spec tool_specs() :: [map()]
  def tool_specs do
    contract()
    |> Map.fetch!("tools")
    |> Enum.map(fn tool ->
      %{
        "name" => tool["name"],
        "description" => tool["description"],
        "inputSchema" => resolve_refs(tool["inputSchema"])
      }
    end)
  end

  @doc "The tool names this build actually implements."
  @spec supported_tools() :: [String.t()]
  def supported_tools do
    ~w(engineering_report engineering_read engineering_plan_loaded engineering_blob_import
       engineering_architecture_publish engineering_device_lease engineering_device_action)
  end

  @doc """
  Execute one engineering tool call for the bound run.

  Returns the app-server tool envelope. A tool that is advertised but not yet
  implemented reports `unsupported_capability`; it never silently succeeds.
  """
  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    with {:ok, context} <- bound_context(binding, opts),
         {:ok, arguments} <- normalize_arguments(arguments) do
      dispatch(tool, arguments, context)
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  # ------------------------------------------------------------------
  # Tools
  # ------------------------------------------------------------------

  defp dispatch("engineering_report", arguments, context) do
    with {:ok, report} <- fetch(arguments, "report"),
         {:ok, entity_type} <- fetch(report, "entity_type"),
         :ok <- known_entity_type(entity_type),
         {:ok, entity} <- fetch(report, "entity"),
         {:ok, expected} <- expected_revision(arguments),
         :ok <- machine_may_not_verdict(entity),
         {:ok, payload} <- merge_human_projection(context, entity_type, entity),
         {:ok, record} <-
           Store.append(
             context.project.project_id,
             entity_type,
             entity["id"],
             expected,
             payload,
             context.actor,
             server: context.project.store,
             idempotency_key: Map.get(arguments, "idempotency_key")
           ) do
      event(context, "#{String.downcase(entity_type)}.updated", entity_type, record)

      success(%{
        "ok" => true,
        "entity_id" => record.entity_id,
        "revision" => record.entity_revision,
        "project_seq" => record.project_seq
      })
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  defp dispatch("engineering_read", arguments, context) do
    with {:ok, entity_type} <- fetch(arguments, "entity_type"),
         :ok <- known_entity_type(entity_type),
         {:ok, entity_id} <- fetch(arguments, "entity_id"),
         {:ok, record} <- scoped_get(context, entity_type, entity_id) do
      success(%{
        "ok" => true,
        "entity_id" => record.entity_id,
        "entity_type" => record.entity_type,
        "revision" => record.entity_revision,
        "recorded_at" => record.recorded_at,
        "entity" => record.payload
      })
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  defp dispatch("engineering_plan_loaded", arguments, context) do
    with {:ok, decision_id} <- fetch(arguments, "decision_id"),
         {:ok, plan_revision} <- fetch(arguments, "plan_revision"),
         {:ok, reported_sha} <- fetch(arguments, "decision_sha256"),
         {:ok, workpad} <- read_workpad(context),
         :ok <- plan_matches(workpad, decision_id, plan_revision, reported_sha),
         {:ok, record} <-
           Store.emit_event(
             context.project.project_id,
             "plan.loaded",
             "Decision",
             decision_id,
             server: context.project.store,
             entity_revision: 1,
             run_id: context.run_id,
             actor: context.actor,
             payload: %{
               "decision_id" => decision_id,
               "plan_revision" => plan_revision,
               "decision_sha256" => reported_sha,
               "detail" => "执行器读取了 workpad 中当前采用的计划。"
             }
           ) do
      # The event is bound to the run that read the plan, so "the new plan was
      # adopted by the executor" can be told apart from "a human accepted it".
      success(%{
        "ok" => true,
        "entity_id" => record.entity_id,
        "revision" => record.entity_revision,
        "project_seq" => record.project_seq
      })
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  defp dispatch("engineering_blob_import", arguments, context) do
    with {:ok, relative_path} <- fetch(arguments, "relative_path"),
         {:ok, expected_sha} <- fetch(arguments, "expected_sha256"),
         {:ok, media_type} <- fetch(arguments, "media_type"),
         {:ok, absolute} <- contained_path(context, relative_path),
         {:ok, bytes} <- read_workspace_file(absolute),
         :ok <- verify_digest(bytes, expected_sha),
         {:ok, receipt} <- Store.put_blob(context.project.project_id, bytes, media_type, server: context.project.store) do
      # Only a durable blob is a receipt: a path inside a workspace that is about
      # to be removed is not evidence.
      success(%{"ok" => true, "blob" => receipt})
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  # The agent uploads the delivered bytes with `engineering_blob_import` and then
  # names their hashes here: the manifest, the IR and the HTML are read back from
  # the store and checked, so a caller cannot publish on the strength of a
  # summary it wrote itself.
  defp dispatch("engineering_architecture_publish", arguments, context) do
    with {:ok, artifact_id} <- fetch(arguments, "artifact_id"),
         {:ok, manifest_sha} <- fetch(arguments, "manifest_blob_sha256"),
         {:ok, ir_sha} <- fetch(arguments, "ir_blob_sha256"),
         {:ok, html_sha} <- fetch(arguments, "html_blob_sha256"),
         {:ok, artifact} <-
           Architecture.validate_and_publish(context.project, %{
             "artifact_id" => artifact_id,
             "manifest_blob_sha256" => manifest_sha,
             "ir_blob_sha256" => ir_sha,
             "html_blob_sha256" => html_sha,
             "issue_id" => Map.get(context, :issue_id),
             "idempotency_key" => Map.get(arguments, "idempotency_key")
           }) do
      success(%{"ok" => true, "artifact" => artifact})
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  # The lease owner is the run the tool is bound to, never an argument: a caller
  # cannot name itself someone else's run, and an expired token is refused by the
  # manager rather than renewed into existence here.
  defp dispatch("engineering_device_lease", arguments, context) do
    with {:ok, device_id} <- fetch(arguments, "device_id"),
         {:ok, action} <- fetch(arguments, "action"),
         {:ok, manager} <- device_manager(),
         {:ok, result} <-
           lease(
             action,
             manager,
             device_id,
             Map.get(context, :run_id),
             Map.get(arguments, "generation"),
             Map.get(arguments, "ttl_seconds")
           ) do
      success(%{"ok" => true, "lease" => result})
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  defp dispatch("engineering_device_action", arguments, context) do
    with {:ok, device_id} <- fetch(arguments, "device_id"),
         {:ok, tool_id} <- fetch(arguments, "tool_id"),
         {:ok, generation} <- fetch(arguments, "lease_generation"),
         {:ok, manager} <- device_manager(),
         {:ok, receipt} <- Manager.run_action(manager, device_id, tool_id, Map.get(context, :run_id), generation) do
      # The receipt is the host's, including its outcome: the agent records what
      # happened, it does not decide whether the hardware worked.
      success(%{"ok" => true, "receipt" => receipt})
    else
      {:error, code, details} -> failure(code, details)
    end
  end

  defp dispatch(tool, _arguments, _context) do
    failure(:unsupported_capability, %{
      tool: tool,
      supported: supported_tools(),
      reason: "this build advertises the tool but does not implement it yet"
    })
  end

  # ------------------------------------------------------------------
  # Device tools
  # ------------------------------------------------------------------

  defp device_manager do
    case Process.whereis(Manager) do
      nil -> {:error, :unsupported_capability, %{reason: "这台宿主没有运行设备管理，设备相关工具不可用"}}
      pid -> {:ok, pid}
    end
  end

  defp lease("acquire", manager, device_id, run_id, _generation, ttl_seconds) do
    Manager.acquire_lease(manager, device_id, run_id, ttl_seconds_opts(ttl_seconds))
  end

  defp lease("renew", manager, device_id, run_id, generation, ttl_seconds)
       when is_integer(generation) and generation >= 1 do
    Manager.renew_lease(manager, device_id, run_id, generation, ttl_seconds_opts(ttl_seconds))
  end

  defp lease("release", manager, device_id, run_id, generation, _ttl_seconds)
       when is_integer(generation) and generation >= 1 do
    Manager.release_lease(manager, device_id, run_id, generation)
  end

  defp lease(action, _manager, _device_id, _run_id, _generation, _ttl_seconds) do
    {:error, :invalid_arguments, %{action: action, reason: "renew/release 必须带上的代次 generation"}}
  end

  defp ttl_seconds_opts(nil), do: []
  defp ttl_seconds_opts(seconds) when is_integer(seconds), do: [ttl_seconds: seconds]
  defp ttl_seconds_opts(other), do: [ttl_seconds: other]

  # ------------------------------------------------------------------
  # Projection rules
  # ------------------------------------------------------------------

  # A machine report is not a verdict: an agent may describe its own state but
  # can never write the human review fields, whatever it sends.
  defp machine_may_not_verdict(entity) do
    case get_in(entity, ["state", "human_review_status"]) do
      nil ->
        :ok

      "unseen" ->
        :ok

      other ->
        {:error, :human_verdict_not_allowed, %{human_review_status: other, reason: "只有人的操作可以写入人工审阅状态"}}
    end
  end

  # A human verdict already recorded on the entity outlives any later machine
  # report: an agent may add findings, never erase a review that happened.
  defp merge_human_projection(context, "ProblemCase", entity) do
    current = current_payload(context, "ProblemCase", entity["id"])
    reported = Map.get(entity, "state", %{})
    human = current |> Map.get("state", %{}) |> Map.get("human_review_status")

    if is_binary(human) and human != "unseen" do
      {:ok, Map.put(entity, "state", Map.put(reported, "human_review_status", human))}
    else
      {:ok, entity}
    end
  end

  defp merge_human_projection(_context, _entity_type, entity), do: {:ok, entity}

  defp current_payload(context, entity_type, entity_id) do
    case Store.get(context.project.project_id, entity_type, entity_id, server: context.project.store) do
      {:ok, record} -> record.payload
      {:error, _code, _details} -> %{}
    end
  end

  defp event(context, type, entity_type, record) do
    Store.emit_event(
      context.project.project_id,
      type,
      entity_type,
      record.entity_id,
      server: context.project.store,
      entity_revision: record.entity_revision,
      run_id: context.run_id,
      actor: context.actor,
      payload: %{"detail" => "#{entity_type} 第 #{record.entity_revision} 修订由执行器上报。"}
    )
  end

  # ------------------------------------------------------------------
  # Scope and validation
  # ------------------------------------------------------------------

  defp bound_context(%{context: nil}, _opts), do: {:error, :workbench_unavailable, %{}}

  defp bound_context(%{context: context}, opts) do
    case Keyword.get(opts, :issue) do
      nil ->
        {:error, :missing_issue_scope, %{reason: "engineering tools require the current issue"}}

      issue ->
        run_id = Keyword.get(opts, :run_id) || "run-#{issue.id}"

        {:ok,
         context
         |> Map.put(:issue_id, issue.id)
         |> Map.put(:run_id, run_id)
         |> Map.put(:actor, %{kind: "agent", id: run_id, display_name: "Agent #{run_id}"})}
    end
  end

  defp context(project, opts) do
    %{project: project, run_id: Keyword.get(opts, :run_id)}
  end

  defp known_entity_type(entity_type) when entity_type in @agent_entity_types, do: :ok

  defp known_entity_type(entity_type) do
    {:error, :unsupported_entity_type, %{entity_type: entity_type, supported: @agent_entity_types}}
  end

  # The caller states the revision it last saw; 0 means "create".
  defp expected_revision(arguments) do
    case Map.get(arguments, "expected_revision") do
      revision when is_integer(revision) and revision >= 0 -> {:ok, revision}
      other -> {:error, :invalid_expected_revision, %{expected_revision: other}}
    end
  end

  defp scoped_get(context, entity_type, entity_id) do
    case Store.get(context.project.project_id, entity_type, entity_id, server: context.project.store) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found, _details} -> {:error, :not_found, %{entity_type: entity_type, entity_id: entity_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp read_workpad(context) do
    adapter = context.project.adapter

    if function_exported?(adapter, :get_workpad, 2) do
      adapter.get_workpad(context.issue_id, context.project.tracker_settings |> then(&[tracker_settings: &1]))
      |> case do
        {:ok, %{plan: plan}} when is_map(plan) -> {:ok, plan}
        {:ok, nil} -> {:error, :workpad_missing, %{issue_id: context.issue_id}}
        {:error, code, details} -> {:error, code, details}
      end
    else
      {:error, :unsupported_capability, %{capability: "workpad"}}
    end
  end

  # The agent must have read the *current* plan; reporting a hash that does not
  # match the workpad would claim work against a plan that is not in effect.
  defp plan_matches(plan, decision_id, plan_revision, reported_sha) do
    cond do
      plan["decision_id"] != decision_id ->
        {:error, :plan_mismatch, %{expected: decision_id, found: plan["decision_id"]}}

      plan["plan_revision"] != plan_revision ->
        {:error, :plan_mismatch, %{expected: plan_revision, found: plan["plan_revision"]}}

      plan_sha(plan) != reported_sha ->
        {:error, :plan_hash_mismatch, %{expected: reported_sha, found: plan_sha(plan)}}

      true ->
        :ok
    end
  end

  @doc "The digest an executor must report after reading a plan reference."
  @spec plan_sha(map()) :: String.t()
  def plan_sha(plan) do
    Canonical.sha256(%{
      "decision_id" => plan["decision_id"],
      "decision_sha256" => plan["decision_sha256"],
      "plan_revision" => plan["plan_revision"],
      "constraints" => plan["constraints"] || [],
      "remaining_validation" => plan["remaining_validation"] || []
    })
  end

  defp contained_path(context, relative_path) do
    root = context.project.workspace_root

    with true <- is_binary(root) or {:error, :workspace_root_unknown, %{}},
         {:ok, canonical_root} <- PathSafety.canonicalize(Path.expand(root)),
         {:ok, canonical} <- PathSafety.canonicalize(Path.expand(Path.join(canonical_root, relative_path))),
         :ok <- within(canonical, canonical_root) do
      {:ok, canonical}
    end
  end

  defp within(canonical, root) do
    if canonical == root or String.starts_with?(canonical, root <> "/") do
      :ok
    else
      {:error, :path_outside_workspace, %{path: canonical}}
    end
  end

  defp read_workspace_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_blob_bytes -> File.read(path)
      {:ok, %File.Stat{size: size}} -> {:error, :blob_too_large, %{bytes: size, limit: @max_blob_bytes}}
      {:error, reason} -> {:error, :unreadable_workspace_file, %{path: path, reason: reason}}
    end
  end

  defp verify_digest(bytes, expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      {:error, :digest_mismatch, %{expected: expected, actual: actual}}
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> {:error, :invalid_arguments, %{missing: key}}
      value -> {:ok, value}
    end
  end

  defp fetch(_map, key), do: {:error, :invalid_arguments, %{missing: key}}

  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _error -> {:error, :invalid_arguments, %{reason: "arguments must be a JSON object"}}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments, %{reason: "arguments must be a map"}}

  # ------------------------------------------------------------------
  # Response envelope
  # ------------------------------------------------------------------

  defp success(payload), do: envelope(true, payload)

  defp failure(code, details) do
    envelope(false, %{
      "ok" => false,
      "error" => %{
        "code" => to_string(code),
        "message" => message(code, details),
        "details" => inspect(details)
      }
    })
  end

  defp message(:unsupported_capability, details), do: "该工具在当前部署不可用：#{inspect(Map.get(details, :reason))}"
  defp message(:not_found, details), do: "找不到目标记录：#{inspect(details)}"
  defp message(:revision_conflict, details), do: "修订已变化，请重新读取后再提交：#{inspect(details)}"
  defp message(code, details), do: "#{code}: #{inspect(details)}"

  defp envelope(success?, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success?,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  # ------------------------------------------------------------------
  # Contract
  # ------------------------------------------------------------------

  defp contract do
    @contract
    |> contract_path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp contract_path(name) do
    Application.app_dir(:symphony_elixir, ["priv", "workbench", name])
  end

  @doc """
  Inline every `#/$defs/...` reference so the advertised schema is self-contained.

  The app-server tool format has no reference mechanism, so the canonical
  contract's shared definitions must be resolved before advertising.
  """
  @spec resolve_refs(term()) :: term()
  def resolve_refs(value) do
    resolve_refs(value, contract() |> Map.fetch!("definitions"))
  end

  defp resolve_refs(%{"$ref" => "#/$defs/" <> name}, definitions) do
    definitions
    |> Map.fetch!(name)
    |> resolve_refs(definitions)
  end

  defp resolve_refs(%{} = value, definitions) do
    value
    |> Map.delete("$ref")
    |> Map.new(fn {key, nested} -> {key, resolve_refs(nested, definitions)} end)
  end

  defp resolve_refs(value, definitions) when is_list(value) do
    Enum.map(value, &resolve_refs(&1, definitions))
  end

  defp resolve_refs(value, _definitions), do: value
end
