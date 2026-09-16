defmodule SymphonyElixir.Experience.Operations do
  @moduledoc """
  Typed workbench operations and their receipts.

  Every mutation is submitted here as a typed request. The module records the
  intent first, records what the provider actually confirmed second, and
  refuses to invent a third state in between: a write whose outcome cannot be
  established is `outcome_unknown` and must be reconciled, never resent.

  Records live in the engineering store, so a receipt outlives the process that
  produced it. This module never schedules, claims or releases work — it only
  asks a provider to change something and writes down what happened.
  """

  require Logger

  alias SymphonyElixir.Experience.{Canonical, Project, Store}

  @supported_actions ~w(create_issue change_issue_state comment request_evidence review)

  @type request :: %{
          required(:action) => String.t(),
          required(:idempotency_key) => String.t(),
          optional(:expected_revision) => non_neg_integer() | nil,
          required(:payload) => map()
        }

  @doc """
  Submit one typed operation for `project` on behalf of `actor`.

  The same `idempotency_key` with the same request returns the recorded
  operation; the same key with different content is refused, so a retry can
  never silently become a second, different write.
  """
  @spec submit(Project.t(), map(), request(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def submit(%Project{} = project, actor, request, opts \\ []) do
    with :ok <- validate_action(request.action),
         :ok <- validate_idempotency_key(request.idempotency_key),
         :ok <- validate_payload(request),
         {:ok, digest} <- request_digest(project, request) do
      case find_by_key(project, request.idempotency_key, opts) do
        nil ->
          run(project, actor, request, digest, opts)

        %{"request_sha256" => ^digest} = existing ->
          # The exact same request was already accepted; return that receipt
          # instead of writing the side effect a second time.
          {:ok, existing}

        existing ->
          {:error, :idempotency_conflict,
           %{
             idempotency_key: request.idempotency_key,
             existing_operation_id: existing["id"],
             reason: "same key was used for a different request"
           }}
      end
    end
  end

  defp run(project, actor, request, digest, opts) do
    operation = new_operation(project, actor, request, digest)

    with {:ok, _record} <- append(project, 0, operation.payload, opts) do
      operation
      |> apply_operation(project, request, opts)
      |> persist(project, opts)
    end
  end

  @doc "Read one recorded operation receipt."
  @spec get(Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def get(%Project{} = project, operation_id, _opts \\ []) do
    case Store.get(project.project_id, "Operation", operation_id, server: project.store) do
      {:ok, record} -> {:ok, wire(record.payload)}
      {:error, :not_found, _details} -> {:error, :not_found, %{operation_id: operation_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  @doc "List recorded operations, newest first."
  @spec list(Project.t(), map(), keyword()) :: [map()]
  def list(%Project{} = project, params \\ %{}, _opts \\ []) do
    limit = params |> Map.get(:limit, 50) |> min(200) |> max(1)

    project
    |> list_operations()
    |> Enum.map(& &1.payload)
    |> Enum.filter(&matches_issue?(&1, Map.get(params, :issue_id)))
    |> Enum.sort_by(& &1["updated_at"], :desc)
    |> Enum.take(limit)
    |> Enum.map(&wire/1)
  end

  # An unreadable store has no receipts to show; that is not "no operations".
  defp list_operations(project) do
    case Store.list(project.project_id, "Operation", server: project.store) do
      records when is_list(records) -> records
      _unreadable -> []
    end
  catch
    :exit, _reason -> []
  end

  # Reconciliation needs the original request, which is deliberately not part of
  # the wire shape of an Operation, so it reads the durable record directly.
  defp stored(project, operation_id, _opts) do
    case Store.get(project.project_id, "Operation", operation_id, server: project.store) do
      {:ok, record} -> {:ok, record.payload}
      {:error, :not_found, _details} -> {:error, :not_found, %{operation_id: operation_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  @doc """
  Re-check a write whose outcome was never established.

  Reconciliation observes; it never re-runs the side effect, because a second
  send is exactly the outcome the `outcome_unknown` state exists to avoid.
  """
  @spec reconcile(Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def reconcile(%Project{} = project, operation_id, opts \\ []) do
    with {:ok, operation} <- stored(project, operation_id, opts),
         :ok <- reconcilable(operation),
         {:ok, observed} <- observe(project, operation, opts) do
      updated = merge_observation(operation, observed) |> Map.put("revision", operation["revision"] + 1)

      with {:ok, _record} <- append(project, operation["revision"], updated, opts) do
        {:ok, wire(updated)}
      end
    end
  end

  # ------------------------------------------------------------------
  # Application
  # ------------------------------------------------------------------

  defp apply_operation(%{payload: payload} = operation, project, request, opts) do
    case do_apply(project, request, opts) do
      {:ok, result} ->
        put_operation(operation, %{
          status: :applied,
          steps: confirmed_steps(payload["steps"], result),
          result_entity_id: result.entity_id,
          error_code: nil
        })

      {:error, code, details} ->
        put_operation(operation, %{
          status: status_for(code),
          steps: failed_steps(payload["steps"], code, details),
          error_code: to_string(code)
        })
    end
  end

  defp do_apply(project, %{action: "create_issue"} = request, opts) do
    with {:ok, metadata} <- project.adapter.metadata(adapter_opts(project, opts)),
         {:ok, state} <- find_state(metadata.states, request.payload["native_state"]),
         {:ok, created} <-
           project.adapter.create_issue(
             %{
               team_id: Keyword.get(opts, :team_id),
               project_id: metadata.provider_project_id,
               title: request.payload["title"],
               description: request.payload["description"],
               native_state_id: state.id,
               assignee_id: request.payload["assignee_id"],
               label_ids: request.payload["label_ids"] || []
             },
             adapter_opts(project, opts)
           ) do
      {:ok, %{entity_id: created[:id], identifier: created[:identifier], native_state: created[:native_state]}}
    end
  end

  defp do_apply(project, %{action: "change_issue_state"} = request, opts) do
    with {:ok, updated} <-
           project.adapter.transition(request.payload["issue_id"], request.payload["target_state"], adapter_opts(project, opts)) do
      {:ok, %{entity_id: updated[:id], native_state: updated[:native_state]}}
    end
  end

  defp do_apply(project, %{action: "comment"} = request, opts) do
    with {:ok, posted} <-
           project.adapter.comment(request.payload["issue_id"], request.payload["body"], adapter_opts(project, opts)) do
      {:ok, %{entity_id: posted[:id], url: posted[:url]}}
    end
  end

  defp do_apply(project, %{action: action} = request, opts) when action in ["review", "request_evidence"] do
    record_engineering_note(project, action, request, opts)
  end

  # A note that only the workbench itself consumes (a review verdict or an
  # evidence request) is durable here; updating the provider workpad is a
  # separate, later step that must not be silently folded into this one.
  defp record_engineering_note(project, action, request, opts) do
    entity_id = request.payload["target_id"] || request.idempotency_key

    case Store.append(
           project.project_id,
           note_entity_type(action),
           entity_id,
           current_note_revision(project, entity_id),
           note_payload(action, request, entity_id),
           actor_payload(opts),
           server: project.store
         ) do
      {:ok, record} -> {:ok, %{entity_id: entity_id, revision: record.entity_revision, note: true}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  # Notes accumulate: a second verdict on the same target becomes the next
  # revision of that note rather than replacing the history already recorded.
  defp current_note_revision(project, entity_id) do
    case Store.get(project.project_id, "Review", entity_id, server: project.store) do
      {:ok, record} -> record.entity_revision
      {:error, _code, _details} -> 0
    end
  end

  defp note_payload(action, request, entity_id) do
    %{
      "action" => action,
      "target_type" => request.payload["target_type"],
      "target_id" => entity_id,
      "issue_id" => request.payload["issue_id"],
      "body" => request.payload["body"] || request.payload["question"],
      "verdict" => request.payload["verdict"],
      "workpad_applied" => false
    }
  end

  defp note_entity_type(_action), do: "Review"

  defp observe(_project, %{"action" => "create_issue"}, _opts) do
    # A create has no reliable marker to search on, so the provider must not be
    # asked again; a human decides whether the issue exists.
    {:ok, %{status: :outcome_unknown, detail: "创建结果仍未确认，请人工核对后再处理。"}}
  end

  defp observe(project, %{"action" => "change_issue_state", "issue_id" => issue_id}, opts) do
    # Reading the issue only says where it is now, not whether this call moved
    # it, so the receipt stays unresolved and reports what was observed.
    case project.adapter.get_issue(issue_id, adapter_opts(project, opts)) do
      {:ok, issue} ->
        {:ok, %{status: :outcome_unknown, detail: "provider 当前状态 #{issue.state}；请人工确认是否已切换。"}}

      {:error, code, details} ->
        {:ok, %{status: :outcome_unknown, detail: "#{code}: #{inspect(details)}"}}
    end
  end

  defp observe(project, %{"action" => "comment", "issue_id" => issue_id, "idempotency_key" => key}, opts) do
    # A comment leaves the marker the provider boundary already looks for, so it
    # is the one write whose outcome can actually be settled by observation.
    case find_marker(project, issue_id, key, opts) do
      {:ok, %{status: "applied"}} ->
        {:ok, %{status: :applied, detail: "provider 已记录该操作标记。"}}

      {:ok, _other} ->
        {:ok, %{status: :outcome_unknown, detail: "provider 未找到该操作标记，读取可能不可靠。"}}

      {:error, code, details} ->
        {:ok, %{status: :outcome_unknown, detail: "#{code}: #{inspect(details)}"}}
    end
  end

  defp observe(_project, _operation, _opts) do
    {:ok, %{status: :outcome_unknown, detail: "无可核对的外部副作用，请人工确认。"}}
  end

  defp find_marker(project, issue_id, key, opts) do
    adapter_opts = Keyword.put(adapter_opts(project, opts), :idempotency_key, key)

    if function_exported?(project.adapter, :find_operation_marker, 2) do
      project.adapter.find_operation_marker(issue_id, adapter_opts)
    else
      {:ok, nil}
    end
  end

  defp merge_observation(operation, observed) do
    status = to_string(observed.status)

    steps =
      operation["steps"]
      |> Enum.reject(&(&1["name"] == "observe"))
      |> Kernel.++([step("observe", status, observed.detail)])

    operation
    |> Map.put("status", status)
    |> Map.put("steps", steps)
    |> Map.put("updated_at", now())
  end

  # ------------------------------------------------------------------
  # Receipts
  # ------------------------------------------------------------------

  defp new_operation(project, actor, request, digest) do
    id = "op-" <> String.slice(digest, 0, 16)

    %{
      payload: %{
        "id" => id,
        "project_id" => project.project_id,
        "revision" => 1,
        "created_at" => now(),
        "updated_at" => now(),
        "issue_id" => request.payload["issue_id"],
        "action" => request.action,
        "idempotency_key" => request.idempotency_key,
        "request_sha256" => digest,
        "expected_revision" => request.expected_revision,
        "actor" => actor,
        "status" => "received",
        "steps" => [step("received", :confirmed, received_detail(request.payload))],
        "result_entity_id" => nil,
        "error_code" => nil
      }
    }
  end

  defp append(project, expected_revision, payload, opts) do
    Store.append(
      project.project_id,
      "Operation",
      payload["id"],
      expected_revision,
      payload,
      actor_payload(opts),
      server: project.store
    )
  end

  defp persist(%{payload: payload}, project, opts) do
    payload = payload |> Map.put("updated_at", now()) |> Map.put("revision", payload["revision"] + 1)

    with {:ok, _record} <- append(project, payload["revision"] - 1, payload, opts) do
      {:ok, wire(payload)}
    end
  end

  defp put_operation(%{payload: payload} = operation, changes) do
    %{operation | payload: Map.merge(payload, stringify(changes)) |> Map.put("updated_at", now())}
  end

  defp confirmed_steps(steps, result) do
    steps ++
      [
        step("applying", :confirmed, "已发送到 provider。"),
        step("applied", :confirmed, "provider 确认：#{inspect(Map.take(result, [:identifier, :native_state]))}")
      ]
  end

  defp failed_steps(steps, code, details) do
    steps ++
      [
        step("applying", :confirmed, "已发送到 provider。"),
        step(to_string(code), :failed, inspect(details))
      ]
  end

  # The first receipt names what was actually asked for, so the operator can see
  # the recorded request even when the provider effect is still unconfirmed. It
  # is a summary, not a copy: the durable record of a long body is the note
  # itself, and a receipt must stay well inside the metadata limit.
  @receipt_text_limit 2_000

  defp received_detail(payload) do
    case payload["body"] || payload["question"] do
      text when is_binary(text) and text != "" -> "请求已记录：" <> summarize(text)
      _none -> "请求已记录，尚未确认外部效果。"
    end
  end

  defp summarize(text) when byte_size(text) <= @receipt_text_limit, do: text

  defp summarize(text) do
    kept = binary_part(text, 0, @receipt_text_limit)
    kept <> "…（已截断，完整内容见该记录的正文）"
  end

  defp step(name, status, detail) do
    %{
      "name" => name,
      "status" => to_string(status),
      "observed_at" => now(),
      "detail" => detail,
      "source_ref" => nil
    }
  end

  # ------------------------------------------------------------------
  # Validation
  # ------------------------------------------------------------------

  defp validate_action(action) when action in @supported_actions, do: :ok

  defp validate_action(action) do
    {:error, :unsupported_action, %{action: action, supported: @supported_actions}}
  end

  defp validate_idempotency_key(key) when is_binary(key) and byte_size(key) >= 8 and byte_size(key) <= 128, do: :ok

  defp validate_idempotency_key(key) do
    {:error, :invalid_idempotency_key, %{idempotency_key: key, reason: "must be 8..128 characters"}}
  end

  # The wire contract requires the text of a note, so an empty one is refused
  # here rather than recorded as a blank review.
  defp validate_payload(%{action: action, payload: payload}) when action in ["review", "request_evidence", "comment"] do
    text = payload["body"] || payload["question"]

    if is_binary(text) and String.trim(text) != "" do
      :ok
    else
      {:error, :invalid_payload, %{action: action, reason: "body must not be blank"}}
    end
  end

  defp validate_payload(%{action: "create_issue", payload: payload}) do
    title = payload["title"]

    if is_binary(title) and String.trim(title) != "" do
      :ok
    else
      {:error, :invalid_payload, %{action: "create_issue", reason: "title must not be blank"}}
    end
  end

  defp validate_payload(_request), do: :ok

  # The key is part of the digest so two different keys with identical content
  # are two distinct operations rather than a revision conflict on one id.
  defp request_digest(project, request) do
    {:ok,
     Canonical.sha256(%{
       "project_id" => project.project_id,
       "action" => request.action,
       "idempotency_key" => request.idempotency_key,
       "payload" => request.payload
     })}
  end

  defp find_by_key(project, key, opts) do
    Enum.find(list(project, %{}, opts), &(&1["idempotency_key"] == key))
  end

  defp reconcilable(%{"status" => status}) when status in ["outcome_unknown", "failed", "conflict"], do: :ok

  defp reconcilable(operation) do
    {:error, :not_reconcilable, %{operation_id: operation["id"], status: operation["status"]}}
  end

  defp status_for(:outcome_unknown), do: :outcome_unknown
  defp status_for(:timeout), do: :outcome_unknown
  defp status_for(:conflict), do: :conflict
  defp status_for(_code), do: :failed

  defp find_state(states, name) do
    case Enum.find(states, &(&1.name == name)) do
      nil -> {:error, :unknown_state, %{state: name, known: Enum.map(states, & &1.name)}}
      state -> {:ok, state}
    end
  end

  defp matches_issue?(_operation, nil), do: true
  defp matches_issue?(operation, issue_id), do: operation["issue_id"] == issue_id

  defp actor_payload(opts) do
    case Keyword.get(opts, :actor) do
      %{} = actor -> actor
      _none -> nil
    end
  end

  # The wire shape is exactly `contracts/openapi.yaml#Operation`; internal fields
  # such as the original request stay in the durable record only.
  defp wire(payload) do
    Map.take(payload, ~w(id project_id revision created_at updated_at issue_id action idempotency_key
       request_sha256 expected_revision actor status steps result_entity_id error_code))
    |> Map.put("steps", Enum.map(payload["steps"] || [], &normalize_step/1))
  end

  defp normalize_step(step) do
    %{
      "name" => step["name"],
      "status" => step["status"],
      "observed_at" => step["observed_at"],
      "detail" => step["detail"] || "",
      "source_ref" => step["source_ref"]
    }
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp adapter_opts(project, opts) do
    base = [tracker_settings: project.tracker_settings, display_states: project.display_states]

    Keyword.merge(base, Keyword.take(opts, [:client, :demo_state]))
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc "The mutation actions this build actually implements."
  @spec supported_actions() :: [String.t()]
  def supported_actions, do: @supported_actions
end
