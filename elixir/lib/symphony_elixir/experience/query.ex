defmodule SymphonyElixir.Experience.Query do
  @moduledoc """
  Read model over the engineering store, the provider and the running scheduler.

  Aggregation only: this module never schedules, claims or releases anything. It
  reports the freshness of each source it read so a caller can tell "the tracker
  has not answered since 10:04" apart from "there are no issues".
  """

  alias SymphonyElixir.Experience.{Canonical, Cursor, DisplayMapping, IssueView, Project, Store}
  alias SymphonyElixir.Tracker.Issue

  @default_limit 50
  @max_limit 200

  @engineering_entity_types ~w(ProblemCase Evidence Validation Decision Review Operation ArchitectureArtifact BuildRecord Device DeviceSession)

  @spec snapshot(Project.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def snapshot(%Project{} = project, opts \\ []) do
    now = DateTime.utc_now()
    runtime = runtime_snapshot(opts)
    issue_result = list_issues(project, %{}, opts)

    issues =
      case issue_result do
        {:ok, %{items: items}} -> items
        {:error, _code, _details} -> []
      end

    counts = counts_by_column(issues, project)
    paused = paused_count(issue_result)

    {:ok,
     %{
       "project_id" => project.project_id,
       "snapshot_seq" => snapshot_seq(project, opts),
       "generated_at" => DateTime.to_iso8601(now),
       "tracker_fetched_at" => tracker_fetched_at(issue_result, now),
       "runtime_observed_at" => runtime_observed_at(runtime, now),
       "source_health" => source_health(project, issue_result, runtime),
       "issue_count" => length(issues),
       "running_count" => runtime_count(runtime),
       "review_count" => Map.get(counts, review_column(project), 0),
       "paused_count" => paused
     }}
  end

  @doc """
  List issues with the board filters applied, newest provider revision first
  inside each display column.

  Returns `{:ok, %{items: [wire_issue], next_cursor: nil | binary}}`, or
  `:cursor_expired` when the caller reuses a cursor across a changed filter set.
  """
  @spec list_issues(Project.t(), map(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def list_issues(%Project{} = project, params, opts \\ []) do
    filters = normalize_filters(params)
    limit = clamp_limit(Map.get(params, :limit, @default_limit))

    with {:ok, cursor} <- Cursor.decode(Map.get(params, :cursor)),
         :ok <-
           Cursor.validate(cursor, %{
             "project_id" => project.project_id,
             "filters" => Cursor.fingerprint(filters)
           }),
         {:ok, views, state_options} <- fetch_views(project, opts) do
      filtered = Enum.filter(views, &IssueView.matches?(&1, filters))
      offset = Map.get(cursor, "offset", 0)
      page = filtered |> Enum.drop(offset) |> Enum.take(limit)
      next_offset = offset + length(page)

      next_cursor =
        if next_offset < length(filtered) do
          Cursor.encode(%{
            "project_id" => project.project_id,
            "filters" => Cursor.fingerprint(filters),
            "offset" => next_offset
          })
        end

      {:ok,
       %{
         items: Enum.map(page, &IssueView.to_wire(&1, project.project_id)),
         next_cursor: next_cursor,
         state_options: state_options
       }}
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  @spec get_issue(Project.t(), String.t(), keyword()) :: {:ok, IssueView.t()} | {:error, atom(), map()}
  def get_issue(%Project{} = project, identifier_or_id, opts \\ []) do
    {metadata, state_options} = provider_state_options(project, opts)

    case lookup_issue(project, identifier_or_id, opts) do
      {:ok, %Issue{} = issue} ->
        {:ok, to_view(issue, state_options, metadata, project.display_states)}

      {:error, :not_found, _details} ->
        {:error, :not_found, %{issue_id: identifier_or_id}}

      {:error, code, details} ->
        {:error, code, details}
    end
  end

  @doc """
  Everything the issue detail page needs about one issue, plus a pointer to the
  original runtime view and the provider workpad when the provider has one.
  """
  @spec issue_context(Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def issue_context(%Project{} = project, identifier_or_id, opts \\ []) do
    with {:ok, view} <- get_issue(project, identifier_or_id, opts) do
      plan = fetch_plan(project, view, opts)

      {:ok,
       %{
         "issue_id" => view.id,
         "current_plan" => plan,
         "problem_case_ids" => ids_for_issue(project, "ProblemCase", view.id, opts),
         "evidence_ids" => ids_for_issue(project, "Evidence", view.id, opts),
         "decision_ids" => ids_for_issue(project, "Decision", view.id, opts),
         "runtime_snapshot_url" => "/api/v1/#{view.identifier}",
         "provider_workpad_url" => view.url,
         "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc """
  The change view for one issue's workspace.

  Without a readable workspace there is no diff to show, so the status is
  `unavailable` with the reason rather than an invented patch.
  """
  @spec changes(Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def changes(%Project{} = project, identifier_or_id, opts \\ []) do
    with {:ok, view} <- get_issue(project, identifier_or_id, opts) do
      case Keyword.get(opts, :changes_source) do
        fun when is_function(fun, 1) ->
          fun.(view)

        _none ->
          {:ok,
           %{
             "issue_id" => view.id,
             "status" => "unavailable",
             "base_revision" => nil,
             "head_revision" => nil,
             "worktree_patch_sha256" => nil,
             "diff_blob_sha256" => nil,
             "changed_paths" => [],
             "limitations" => ["未找到该 Issue 的工作区，无法读取变更范围。"]
           }}
      end
    end
  end

  @spec provider_metadata(Project.t(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def provider_metadata(%Project{} = project, opts \\ []) do
    with {:ok, metadata} <- project.adapter.metadata(adapter_opts(project, opts)) do
      {:ok,
       %{
         "project_id" => project.project_id,
         "provider" => metadata.provider,
         "provider_project_id" => metadata.provider_project_id,
         "states" => metadata.states,
         "assignees" => metadata.assignees,
         "labels" => metadata.labels,
         "capabilities" => metadata.capabilities,
         "fetched_at" => metadata.fetched_at,
         "stale" => metadata.stale
       }}
    end
  end

  @doc "List stored engineering entities of one type, newest revision per entity."
  @spec list_entities(Project.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, atom(), map()}
  def list_entities(%Project{} = project, entity_type, _opts \\ []) do
    with :ok <- known_entity_type(entity_type) do
      {:ok, Store.list(project.project_id, entity_type, server: project.store)}
    end
  end

  @spec get_entity(Project.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), map()}
  def get_entity(%Project{} = project, entity_type, entity_id, _opts \\ []) do
    with :ok <- known_entity_type(entity_type),
         {:ok, record} <- Store.get(project.project_id, entity_type, entity_id, server: project.store) do
      {:ok, entity_payload(record)}
    else
      {:error, :not_found, _details} -> {:error, :not_found, %{entity_type: entity_type, entity_id: entity_id}}
      {:error, code, details} -> {:error, code, details}
    end
  end

  @doc "Journal events after a cursor, used to resume a disconnected client."
  @spec events(Project.t(), map(), keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def events(%Project{} = project, params, _opts \\ []) do
    after_seq = Map.get(params, :after_seq, 0)
    limit = params |> Map.get(:limit, 100) |> min(500) |> max(1)

    records = Store.replay(project.project_id, after_seq, limit, server: project.store)

    {:ok,
     %{
       "items" => Enum.map(records, &event_wire(&1, project)),
       "next_cursor" => next_event_cursor(records, after_seq),
       "snapshot_seq" => Store.project_seq(project.project_id, server: project.store)
     }}
  end

  @doc """
  The column counts for the board header, scoped to the same filter set the
  board is showing so a count never disagrees with the visible cards.
  """
  @spec column_counts(Project.t(), map(), keyword()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, atom(), map()}
  def column_counts(%Project{} = project, params \\ %{}, opts \\ []) do
    with {:ok, views, _state_options} <- fetch_views(project, opts) do
      filters = normalize_filters(params)

      counts =
        views
        |> Enum.filter(&IssueView.matches?(&1, filters))
        |> DisplayMapping.count_by_column(project.display_states)

      {:ok, counts}
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp fetch_views(project, opts) do
    {metadata, state_options} = provider_state_options(project, opts)

    adapter_opts =
      project
      |> adapter_opts(opts)
      |> Keyword.put(:state_names, project.display_states)

    case project.adapter.list_issues(adapter_opts) do
      {:ok, issues} ->
        views =
          issues
          |> Enum.map(&to_view(&1, state_options, metadata, project.display_states))
          |> DisplayMapping.sort_by_column(project.display_states)

        {:ok, views, state_options}

      {:error, code, details} ->
        {:error, code, details}
    end
  end

  defp to_view(issue, state_options, metadata, display_states) do
    IssueView.from_tracker(issue, state_options,
      display_states: display_states,
      provider: (metadata && metadata.provider) || "unknown",
      capabilities: capabilities_for(metadata)
    )
  end

  defp capabilities_for(nil), do: []
  defp capabilities_for(metadata), do: Map.get(metadata, :capabilities, [])

  defp provider_state_options(project, opts) do
    case project.adapter.metadata(adapter_opts(project, opts)) do
      {:ok, metadata} -> {metadata, column_options(metadata.states, project.display_states)}
      {:error, _code, _details} -> {nil, []}
    end
  end

  defp column_options(states, display_states) do
    Enum.map(states, fn state ->
      %{
        name: state.name,
        active: state.active,
        terminal: state.terminal,
        display_column:
          Map.get(state, :display_column) ||
            DisplayMapping.column_for(state.name, state.active, state.terminal, display_states)
      }
    end)
  end

  defp lookup_issue(project, identifier_or_id, opts) do
    adapter_opts = adapter_opts(project, opts)

    case project.adapter.get_issue(identifier_or_id, adapter_opts) do
      {:ok, %Issue{} = issue} ->
        {:ok, issue}

      {:error, :not_found, details} ->
        lookup_by_identifier(project, identifier_or_id, adapter_opts, details)

      {:error, code, details} ->
        {:error, code, details}
    end
  end

  defp lookup_by_identifier(project, identifier, adapter_opts, details) do
    with {:ok, issues} <- project.adapter.list_issues(Keyword.put(adapter_opts, :state_names, project.display_states)) do
      case Enum.find(issues, &(&1.identifier == identifier)) do
        nil -> {:error, :not_found, details}
        issue -> {:ok, issue}
      end
    end
  end

  defp fetch_plan(project, view, opts) do
    case function_exported?(project.adapter, :get_workpad, 2) do
      false ->
        nil

      true ->
        case project.adapter.get_workpad(view.id, adapter_opts(project, opts)) do
          {:ok, %{plan: plan}} when is_map(plan) -> plan_reference(project, view, plan)
          _other -> nil
        end
    end
  end

  defp plan_reference(project, view, plan) do
    plan_revision = plan["plan_revision"] || "unknown"

    %{
      "decision_id" => plan["decision_id"],
      "decision_revision" => plan["decision_revision"],
      "plan_revision" => plan_revision,
      "plan_sha256" =>
        Canonical.sha256(%{
          "decision_id" => plan["decision_id"],
          "decision_sha256" => plan["decision_sha256"],
          "plan_revision" => plan_revision,
          "constraints" => plan["constraints"] || [],
          "remaining_validation" => plan["remaining_validation"] || []
        }),
      "plan_blob_sha256" => nil,
      "workpad_url" => view.url,
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "project_id" => project.project_id
    }
  end

  defp ids_for_issue(project, entity_type, issue_id, _opts) do
    project.project_id
    |> Store.list(entity_type, server: project.store)
    |> Enum.filter(&entity_references_issue?(&1, issue_id))
    |> Enum.map(& &1.entity_id)
  end

  defp entity_references_issue?(record, issue_id) do
    payload = record.payload
    ids = Map.get(payload, "issue_ids") || List.wrap(Map.get(payload, "issue_id"))
    issue_id in ids
  end

  defp entity_payload(record) do
    record.payload
    |> Map.put("id", record.entity_id)
    |> Map.put("revision", record.entity_revision)
    |> Map.put("recorded_at", record.recorded_at)
  end

  defp event_wire(record, project) do
    payload = record.payload

    %{
      "event_id" => payload["event_id"] || record.entity_id,
      "project_id" => project.project_id,
      "project_seq" => record.project_seq,
      "occurred_at" => payload["occurred_at"] || record.recorded_at,
      "recorded_at" => record.recorded_at,
      "type" => payload["type"],
      "entity_type" => payload["entity_type"] || record.entity_type,
      "entity_id" => payload["entity_id"] || record.entity_id,
      "entity_revision" => payload["entity_revision"] || record.entity_revision,
      "run_id" => payload["run_id"],
      "actor" => record.actor,
      "payload" => payload["payload"] || %{}
    }
  end

  defp next_event_cursor([], after_seq), do: after_seq
  defp next_event_cursor(records, _after_seq), do: List.last(records).project_seq

  defp snapshot_seq(project, _opts) do
    Store.project_seq(project.project_id, server: project.store)
  catch
    # A store that cannot answer must not take the whole snapshot read down.
    :exit, _reason -> 0
  end

  defp tracker_fetched_at({:ok, _page}, now), do: DateTime.to_iso8601(now)
  defp tracker_fetched_at({:error, _code, _details}, _now), do: nil

  defp runtime_count(nil), do: 0
  defp runtime_count(runtime), do: Map.get(runtime, :running_count, 0)

  defp runtime_observed_at(nil, _now), do: nil
  defp runtime_observed_at(_runtime, now), do: DateTime.to_iso8601(now)

  defp runtime_snapshot(opts) do
    case Keyword.get(opts, :runtime_snapshot) do
      fun when is_function(fun, 0) -> fun.()
      nil -> safe_runtime_snapshot()
    end
  end

  # `Orchestrator.snapshot/2` already turns a missing or unresponsive scheduler
  # into `:timeout | :unavailable`, so a degraded runtime is a normal read here.
  defp safe_runtime_snapshot do
    case SymphonyElixir.Orchestrator.snapshot() do
      %{running: running} when is_list(running) -> %{running_count: length(running)}
      _unavailable -> nil
    end
  end

  defp source_health(project, issue_result, runtime) do
    [
      %{
        "source" => "store",
        "status" => "healthy",
        "last_success_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "detail" => ""
      },
      %{
        "source" => "tracker",
        "status" => tracker_status(issue_result),
        "last_success_at" => tracker_fetched_at(issue_result, DateTime.utc_now()),
        "detail" => tracker_detail(issue_result, project)
      },
      %{
        "source" => "runtime",
        "status" => if(runtime, do: "healthy", else: "unavailable"),
        "last_success_at" => runtime_observed_at(runtime, DateTime.utc_now()),
        "detail" => if(runtime, do: "", else: "原 runtime snapshot 暂不可读。")
      }
    ]
  end

  # A paused issue is one the scheduler will not dispatch (the provider says the
  # state is not active) but that is not finished either (not terminal). That is
  # derived from provider metadata, not from a second workbench workflow.
  defp paused_count({:ok, %{items: items, state_options: state_options}}) do
    by_name = Map.new(state_options, &{&1.name, &1})

    Enum.count(items, fn item ->
      case Map.get(by_name, item["native_state"]) do
        %{active: false, terminal: false} -> true
        _other -> false
      end
    end)
  end

  defp paused_count(_issue_result), do: 0

  defp tracker_status({:ok, _page}), do: "healthy"
  defp tracker_status({:error, :permission_denied, _details}), do: "unavailable"
  defp tracker_status({:error, _code, _details}), do: "degraded"

  defp tracker_detail({:ok, _page}, _project), do: ""

  defp tracker_detail({:error, code, details}, project) do
    "#{project.adapter} #{code}: #{inspect(details)}"
  end

  defp review_column(%Project{display_states: states}) do
    Enum.find(states, "", fn column -> column in ["Human Review", "待审阅", "Review"] end)
  end

  defp counts_by_column(views, _project) do
    views
    |> Enum.map(&Map.get(&1, "display_column"))
    |> Enum.frequencies()
    |> Map.new()
  end

  defp normalize_filters(params) do
    %{
      q: Map.get(params, :q),
      state: Map.get(params, :state),
      column: Map.get(params, :column),
      assignee: Map.get(params, :assignee)
    }
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit

  defp known_entity_type(entity_type) do
    if entity_type in @engineering_entity_types do
      :ok
    else
      {:error, :unsupported_entity_type, %{entity_type: entity_type, known: @engineering_entity_types}}
    end
  end

  defp adapter_opts(project, opts) do
    base = [
      tracker_settings: project.tracker_settings,
      display_states: project.display_states,
      project_id: project.project_id
    ]

    Keyword.merge(base, Keyword.take(opts, [:client, :demo_state]))
  end
end
