defmodule SymphonyElixir.Linear.WorkbenchAdapter do
  @moduledoc """
  Linear implementation of the workbench provider boundary.

  Reads and writes go through the same host GraphQL client the tracker adapter
  uses, but nothing here is added to the orchestrator: the scheduler keeps its
  read-only view while the workbench gains provider-owned mutations.

  Every mutation returns `{:ok, ...}` only for a provider-confirmed effect. A
  call whose result cannot be established is reported as `:outcome_unknown` so
  the caller reconciles instead of retrying a write that may already have landed.
  """

  @behaviour SymphonyElixir.Experience.WorkbenchAdapter

  alias SymphonyElixir.Experience.DisplayMapping
  alias SymphonyElixir.Experience.WorkbenchAdapter
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 50
  @workpad_marker "## Codex Workpad"
  @plan_marker "<!-- symphony-engineering-plan -->"

  @issue_fields """
        id
        identifier
        title
        description
        state { id name }
        url
        assignee { id name }
        labels { nodes { id name } }
        createdAt
        updatedAt
  """

  @list_query """
  query SymphonyWorkbenchIssues($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
  #{@issue_fields}
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @issue_query """
  query SymphonyWorkbenchIssue($id: String!, $projectSlug: String!) {
    issue(id: $id) {
  #{@issue_fields}
    }
    project(id: $projectSlug) { id }
  }
  """

  @metadata_query """
  query SymphonyWorkbenchMetadata {
    viewer { organization { id name } }
    teams(first: 1) { nodes { id name states { nodes { id name type position } } } }
    users(first: 100) { nodes { id name displayName } }
    issueLabels(first: 100) { nodes { id name } }
  }
  """

  @project_query """
  query SymphonyWorkbenchProject($projectSlug: String!) {
    project(id: $projectSlug) {
      id
      name
      teams { nodes { id name states { nodes { id name type position } } } }
    }
  }
  """

  @comments_query """
  query SymphonyWorkbenchComments($issueId: String!, $first: Int!, $after: String) {
    issue(id: $issueId) {
      comments(first: $first, after: $after) {
        nodes { id body resolvedAt updatedAt }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @create_mutation """
  mutation SymphonyWorkbenchCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue { id identifier state { id name } url }
    }
  }
  """

  @update_mutation """
  mutation SymphonyWorkbenchUpdate($id: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $id, input: $input) {
      success
      issue { id identifier state { id name } updatedAt }
    }
  }
  """

  @comment_create_mutation """
  mutation SymphonyWorkbenchComment($input: CommentCreateInput!) {
    commentCreate(input: $input) {
      success
      comment { id url }
    }
  }
  """

  @comment_update_mutation """
  mutation SymphonyWorkbenchCommentUpdate($id: String!, $input: CommentUpdateInput!) {
    commentUpdate(id: $id, input: $input) {
      success
      comment { id updatedAt }
    }
  }
  """

  # ------------------------------------------------------------------
  # Capabilities and metadata
  # ------------------------------------------------------------------

  @impl true
  def capabilities do
    [
      cap("read", true),
      cap("create_issue", true),
      cap("comment", true),
      cap("change_state", true),
      cap("pause", true),
      cap("resume", true),
      cap("workpad", true),
      cap("native_url", true)
    ]
  end

  @impl true
  def secret_environment_names, do: ["LINEAR_API_KEY"]

  @impl true
  def metadata(opts \\ []) do
    with {:ok, tracker} <- tracker(opts),
         {:ok, body} <- graphql(@project_query, %{"projectSlug" => tracker.project_slug}, opts) do
      project = body["data"]["project"] || %{}
      teams = get_in(project, ["teams", "nodes"]) || []

      {:ok,
       %{
         provider: "linear",
         provider_project_id: project["id"] || tracker.project_slug,
         states: states_from_teams(teams, opts),
         assignees: [],
         labels: [],
         capabilities: capabilities(),
         fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         stale: false
       }}
    else
      {:error, code, details} -> {:error, code, details}
    end
  end

  @doc """
  Provider metadata used by the new-issue form.

  Assignees and labels are fetched separately from workflow states because a
  board that cannot list them must still be able to open a form and say which
  field is unavailable, rather than inventing options.
  """
  @spec form_metadata(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def form_metadata(opts \\ []) do
    with {:ok, states} <- metadata(opts),
         {:ok, body} <- graphql(@metadata_query, %{}, opts) do
      {:ok,
       %{
         states
         | assignees: users(body),
           labels: labels(body)
       }}
    end
  end

  @impl true
  def validate_metadata(opts \\ []) do
    with {:ok, metadata} <- metadata(opts) do
      require_states(metadata.states)
    end
  end

  # ------------------------------------------------------------------
  # Reads
  # ------------------------------------------------------------------

  @impl true
  def list_issues(opts \\ []) do
    state_names = Keyword.get(opts, :state_names, [])
    cursor = Keyword.get(opts, :cursor)

    with {:ok, tracker} <- tracker(opts) do
      fetch_page(tracker.project_slug, state_names, cursor, opts, [])
    end
  end

  defp fetch_page(project_slug, state_names, cursor, opts, acc) do
    variables = %{
      "projectSlug" => project_slug,
      "stateNames" => state_names,
      "first" => @issue_page_size,
      "after" => cursor
    }

    with {:ok, body} <- graphql(@list_query, variables, opts) do
      connection = get_in(body, ["data", "issues"]) || %{}
      issues = connection |> Map.get("nodes", []) |> Enum.map(&normalize_issue/1)
      acc = acc ++ issues

      case get_in(connection, ["pageInfo", "endCursor"]) do
        next when is_binary(next) and next != "" -> fetch_page(project_slug, state_names, next, opts, acc)
        _done -> {:ok, acc}
      end
    end
  end

  @impl true
  def get_issue(issue_id, opts \\ []) do
    with {:ok, tracker} <- tracker(opts),
         {:ok, body} <- graphql(@issue_query, %{"id" => issue_id, "projectSlug" => tracker.project_slug}, opts) do
      case get_in(body, ["data", "issue"]) do
        nil -> {:error, :not_found, %{issue_id: issue_id}}
        issue -> {:ok, normalize_issue(issue)}
      end
    end
  end

  # ------------------------------------------------------------------
  # Writes
  # ------------------------------------------------------------------

  @impl true
  def create_issue(attrs, opts \\ []) do
    with {:ok, _tracker} <- tracker(opts),
         :ok <- validate_metadata(opts) do
      case graphql(@create_mutation, %{"input" => create_input(attrs)}, opts) do
        {:ok, body} -> interpret_create(attrs, get_in(body, ["data", "issueCreate"]))
        # The write may or may not have landed; never blindly resend a create.
        {:error, :timeout, details} -> {:error, :outcome_unknown, details}
        {:error, code, details} -> {:error, code, details}
      end
    end
  end

  defp create_input(attrs) do
    %{
      "teamId" => attrs[:team_id],
      "projectId" => attrs[:project_id],
      "title" => attrs[:title],
      "description" => attrs[:description] || ""
    }
    |> put_present("stateId", attrs[:native_state_id])
    |> put_present("assigneeId", attrs[:assignee_id])
    |> put_present("labelIds", attrs[:label_ids])
  end

  defp interpret_create(_attrs, %{"success" => true, "issue" => issue}) when is_map(issue) do
    {:ok, normalize_write(issue)}
  end

  defp interpret_create(_attrs, %{"issue" => issue}) when is_map(issue) do
    {:ok, normalize_write(issue)}
  end

  defp interpret_create(attrs, _other), do: {:error, :create_rejected, %{attrs: attrs}}

  @impl true
  def transition(issue_id, target_state_name, opts \\ []) do
    with {:ok, metadata} <- metadata(opts),
         {:ok, state_id} <- state_id(metadata.states, target_state_name),
         {:ok, body} <- graphql(@update_mutation, %{"id" => issue_id, "input" => %{"stateId" => state_id}}, opts) do
      case get_in(body, ["data", "issueUpdate"]) do
        %{"success" => true, "issue" => issue} -> {:ok, normalize_write(issue)}
        _other -> {:error, :transition_rejected, %{issue_id: issue_id, target_state: target_state_name}}
      end
    else
      {:error, :timeout, details} -> {:error, :outcome_unknown, details}
      {:error, code, details} -> {:error, code, details}
    end
  end

  @impl true
  def comment(issue_id, body_text, opts \\ []) do
    with {:ok, _tracker} <- tracker(opts) do
      write_comment(issue_id, body_text, opts)
    end
  end

  defp write_comment(issue_id, body_text, opts) do
    case graphql(@comment_create_mutation, %{"input" => %{"issueId" => issue_id, "body" => body_text}}, opts) do
      {:ok, body} -> interpret_comment(issue_id, get_in(body, ["data", "commentCreate"]))
      {:error, :timeout, details} -> {:error, :outcome_unknown, details}
      {:error, code, details} -> {:error, code, details}
    end
  end

  defp interpret_comment(_issue_id, %{"success" => true, "comment" => comment}) do
    {:ok, %{id: comment["id"], url: comment["url"]}}
  end

  defp interpret_comment(issue_id, _other), do: {:error, :comment_rejected, %{issue_id: issue_id}}

  # ------------------------------------------------------------------
  # Workpad
  # ------------------------------------------------------------------

  @impl true
  def find_operation_marker(issue_id, opts \\ []) do
    with {:ok, comments} <- comments(issue_id, opts) do
      marker =
        comments
        |> Enum.find(fn comment -> String.contains?(comment["body"] || "", operation_marker_prefix(opts)) end)

      case marker do
        nil -> {:ok, nil}
        comment -> {:ok, parse_operation_marker(comment)}
      end
    end
  end

  @impl true
  def get_workpad(issue_id, opts \\ []) do
    with {:ok, comments} <- comments(issue_id, opts) do
      case Enum.find(comments, &workpad?/1) do
        nil -> {:ok, nil}
        comment -> {:ok, %{id: comment["id"], plan: parse_plan(comment["body"] || "")}}
      end
    end
  end

  @impl true
  def update_workpad_plan(issue_id, plan, opts \\ []) do
    with {:ok, comments} <- comments(issue_id, opts),
         {:ok, workpad} <- require_workpad(comments, issue_id) do
      body = put_plan(workpad["body"] || "", plan)

      case graphql(@comment_update_mutation, %{"id" => workpad["id"], "input" => %{"body" => body}}, opts) do
        {:ok, response} -> interpret_workpad_update(issue_id, plan, get_in(response, ["data", "commentUpdate"]))
        {:error, :timeout, details} -> {:error, :outcome_unknown, details}
        {:error, code, details} -> {:error, code, details}
      end
    end
  end

  defp interpret_workpad_update(_issue_id, plan, %{"success" => true, "comment" => comment}) do
    {:ok, %{id: comment["id"], plan: plan}}
  end

  defp interpret_workpad_update(issue_id, _plan, _other) do
    {:error, :workpad_update_rejected, %{issue_id: issue_id}}
  end

  defp comments(issue_id, opts) do
    with {:ok, _tracker} <- tracker(opts) do
      gather_comments(issue_id, nil, opts, [])
    end
  end

  defp gather_comments(issue_id, cursor, opts, acc) do
    variables = %{"issueId" => issue_id, "first" => 50, "after" => cursor}

    with {:ok, body} <- graphql(@comments_query, variables, opts) do
      connection = get_in(body, ["data", "issue", "comments"]) || %{}
      comments = acc ++ Map.get(connection, "nodes", [])

      case get_in(connection, ["pageInfo", "endCursor"]) do
        next when is_binary(next) and next != "" -> gather_comments(issue_id, next, opts, comments)
        _done -> {:ok, comments}
      end
    end
  end

  defp require_workpad(comments, issue_id) do
    case Enum.find(comments, &workpad?/1) do
      nil -> {:error, :workpad_missing, %{issue_id: issue_id, marker: @workpad_marker}}
      comment -> {:ok, comment}
    end
  end

  defp workpad?(%{"body" => body, "resolvedAt" => nil}) when is_binary(body) do
    String.contains?(body, @workpad_marker)
  end

  defp workpad?(_comment), do: false

  @doc """
  Render the plan reference that `get_workpad/2` reads back.

  The section is delimited so an unrelated comment edit cannot silently change
  the plan the executor is running under.
  """
  @spec put_plan(String.t(), map()) :: String.t()
  def put_plan(body, plan) do
    section = render_plan(plan)

    case Regex.run(~r/#{Regex.escape(@plan_marker)}.*?#{Regex.escape(@plan_marker)}/s, body) do
      [existing] -> String.replace(body, existing, section)
      nil -> String.trim_trailing(body) <> "\n\n" <> section <> "\n"
    end
  end

  @doc "Read the plan reference back out of a workpad body."
  @spec parse_plan(String.t()) :: map() | nil
  def parse_plan(body) when is_binary(body) do
    case Regex.run(~r/#{Regex.escape(@plan_marker)}(.*?)#{Regex.escape(@plan_marker)}/s, body) do
      [_full, inner] -> read_plan_fields(inner)
      nil -> nil
    end
  end

  defp read_plan_fields(inner) do
    fields =
      inner
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^-\s*([a-z_]+):\s*(.*)$/, String.trim(line)) do
          [_full, key, value] -> [{key, String.trim(value)}]
          nil -> []
        end
      end)
      |> Map.new()

    %{
      "decision_id" => empty_to_nil(fields["decision_id"]),
      "decision_revision" => parse_int(fields["decision_revision"]),
      "decision_sha256" => empty_to_nil(fields["decision_sha256"]),
      "plan_revision" => empty_to_nil(fields["plan_revision"]),
      "constraints" => split_list(fields["constraints"]),
      "remaining_validation" => split_list(fields["remaining_validation"])
    }
  end

  defp render_plan(plan) do
    """
    #{@plan_marker}
    - decision_id: #{plan[:decision_id] || ""}
    - decision_revision: #{plan[:decision_revision] || ""}
    - decision_sha256: #{plan[:decision_sha256] || ""}
    - plan_revision: #{plan[:plan_revision] || ""}
    - constraints: #{Enum.join(plan[:constraints] || [], " | ")}
    - remaining_validation: #{Enum.join(plan[:remaining_validation] || [], " | ")}
    #{@plan_marker}
    """
  end

  defp operation_marker_prefix(opts) do
    "<!-- symphony-operation:#{Keyword.get(opts, :idempotency_key, "")}"
  end

  defp parse_operation_marker(comment) do
    case Regex.run(~r/<!-- symphony-operation:(\S+):(\S+) -->/, comment["body"] || "") do
      [_full, key, status] -> %{comment_id: comment["id"], idempotency_key: key, status: status}
      nil -> %{comment_id: comment["id"], idempotency_key: nil, status: "unknown"}
    end
  end

  # ------------------------------------------------------------------
  # GraphQL plumbing
  # ------------------------------------------------------------------

  defp graphql(query, variables, opts) do
    client = Keyword.get(opts, :client, client_module())

    case client.graphql(query, variables) do
      {:ok, body} -> unwrap_errors(body)
      {:error, reason} -> normalize_graphql_error(reason)
    end
  end

  defp unwrap_errors(body) when is_map(body) do
    case Map.get(body, "errors") do
      [%{"message" => message} | _rest] -> {:error, :provider_error, %{message: message}}
      _none -> {:ok, body}
    end
  end

  defp unwrap_errors(other), do: {:error, :provider_error, %{body: other}}

  defp normalize_graphql_error({:http_error, status, _body}) when status in [401, 403] do
    {:error, :permission_denied, %{status: status}}
  end

  defp normalize_graphql_error({:http_error, status, _body}) do
    {:error, :provider_unavailable, %{status: status}}
  end

  defp normalize_graphql_error(:timeout), do: {:error, :timeout, %{}}
  defp normalize_graphql_error(reason), do: {:error, :provider_unavailable, %{reason: reason}}

  defp tracker(opts) do
    case Keyword.get(opts, :tracker_settings) do
      %{project_slug: slug} = settings when is_binary(slug) and slug != "" -> {:ok, settings}
      _missing -> {:error, :missing_linear_project_slug, %{}}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  # ------------------------------------------------------------------
  # Normalization
  # ------------------------------------------------------------------

  defp normalize_issue(issue) do
    %Issue{
      id: issue["id"],
      native_ref: %{"linear" => issue["id"]},
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: get_in(issue, ["state", "name"]),
      url: issue["url"],
      assignee_id: get_in(issue, ["assignee", "id"]),
      labels: issue |> Map.get("labels", %{}) |> Map.get("nodes", []) |> Enum.map(& &1["name"]),
      dispatchable: false,
      created_at: parse_time(issue["createdAt"]),
      updated_at: parse_time(issue["updatedAt"])
    }
  end

  defp normalize_write(issue) do
    %{
      id: issue["id"],
      identifier: issue["identifier"],
      native_state: get_in(issue, ["state", "name"]),
      url: issue["url"],
      updated_at: issue["updatedAt"]
    }
  end

  defp states_from_teams(teams, opts) do
    display_states = Keyword.get(opts, :display_states, [])

    teams
    |> Enum.flat_map(&(get_in(&1, ["states", "nodes"]) |> List.wrap()))
    |> Enum.map(fn state ->
      {active, terminal} = state_flags(state["type"])

      %{
        id: state["id"],
        name: state["name"],
        display_column: DisplayMapping.column_for(state["name"], active, terminal, display_states),
        active: active,
        terminal: terminal
      }
    end)
    |> Enum.uniq_by(& &1.id)
  end

  # Linear workflow state types: backlog/unstarted/started map to "active" for
  # board purposes; completed/canceled are terminal; nothing else is assumed.
  defp state_flags("started"), do: {true, false}
  defp state_flags("unstarted"), do: {true, false}
  defp state_flags("backlog"), do: {false, false}
  defp state_flags("completed"), do: {false, true}
  defp state_flags("canceled"), do: {false, true}
  defp state_flags(_other), do: {false, false}

  defp users(body) do
    body
    |> get_in(["data", "users", "nodes"])
    |> List.wrap()
    |> Enum.map(fn user -> %{id: user["id"], name: user["displayName"] || user["name"] || user["id"]} end)
  end

  defp labels(body) do
    body
    |> get_in(["data", "issueLabels", "nodes"])
    |> List.wrap()
    |> Enum.map(fn label -> %{id: label["id"], name: label["name"]} end)
  end

  defp require_states([]), do: {:error, :no_provider_states, %{reason: "provider returned no workflow states"}}
  defp require_states(_states), do: :ok

  defp state_id(states, name) do
    case Enum.find(states, &(&1.name == name)) do
      nil -> {:error, :unknown_state, %{state: name, known: Enum.map(states, & &1.name)}}
      state -> {:ok, state.id}
    end
  end

  defp cap(name, available) do
    WorkbenchAdapter.capability(name, available, nil)
  end

  defp put_present(map, _key, value) when value in [nil, [], ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(value), do: value

  defp split_list(nil), do: []
  defp split_list(""), do: []
  defp split_list(value), do: value |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end
end
