defmodule SymphonyElixirWeb.Workbench.IssuesLive do
  @moduledoc """
  The Issues board: the workbench's task entry point.

  Every card shown here comes from the provider. The four columns are a display
  mapping over native states, so no issue disappears because it happens to be
  outside the orchestrator's running set.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :workbench}

  alias SymphonyElixir.Experience.{DemoAdapter, Operations, Project, Query}
  alias SymphonyElixirWeb.WorkbenchComponents

  @impl true
  def mount(_params, _session, socket) do
    case Project.load() do
      {:ok, project} ->
        {:ok,
         assign(socket,
           project: project,
           unavailable: nil,
           filters: %{},
           pending: nil,
           form_error: nil,
           submitting: false,
           create_open: false,
           create_draft: empty_draft(),
           items: [],
           columns: [],
           column_counts: %{},
           issue_count: 0,
           snapshot: nil,
           load_error: nil,
           state_options: [],
           assignees: []
         )}

      {:error, code, details} ->
        {:ok, assign(socket, unavailable: {code, details}, filters: %{})}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:project] do
      {:noreply, socket |> assign(:filters, params) |> load_board()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create", %{"issue" => attrs}, socket) do
    project = socket.assigns.project
    key = socket.assigns.pending

    request = %{
      action: "create_issue",
      idempotency_key: key,
      expected_revision: nil,
      payload: %{
        "title" => attrs["title"],
        "description" => attrs["description"] || "",
        "native_state" => attrs["native_state"],
        "assignee_id" => blank_to_nil(attrs["assignee_id"]),
        "label_ids" => []
      }
    }

    # Hold the submitted values before the write so a refusal cannot lose them.
    socket = socket |> assign(:submitting, true) |> assign(:create_draft, Map.merge(socket.assigns.create_draft, attrs))

    case Operations.submit(project, local_actor(), request) do
      {:ok, operation} ->
        # A write the provider did not confirm must not close the form: the
        # operator still has to see what was refused.
        {:noreply,
         socket
         |> assign(
           submitting: false,
           create_open: not WorkbenchComponents.applied?(operation),
           create_draft: next_draft(socket, operation),
           form_error: WorkbenchComponents.receipt_warning(operation)
         )
         |> load_board()}

      {:error, code, details} ->
        {:noreply,
         socket
         |> assign(submitting: false, form_error: "创建失败：#{code} #{inspect(details)}")
         |> load_board()}
    end
  end

  def handle_event("toggle-create", _params, socket) do
    {:noreply,
     assign(socket,
       create_open: not socket.assigns.create_open,
       create_draft: empty_draft(),
       form_error: nil,
       pending: new_key()
     )}
  end

  @doc false
  @impl true
  def handle_event("create-draft", %{"issue" => attrs}, socket) do
    # Held server-side so a refused submit never eats what the operator typed.
    {:noreply, assign(socket, :create_draft, Map.merge(socket.assigns.create_draft, attrs))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
    <WorkbenchComponents.shell
      :if={!@unavailable}
      active="/workbench/issues"
      project_id={@project.project_id}
      notice={demo_notice(@project)}
      error={@form_error}
    >
      <:toolbar>
        <div class="wb-page-head">
          <h1 class="wb-title">Issues</h1>
          <p class="wb-subtitle">
            {summary(@snapshot)}
          </p>
          <div class="wb-spacer"></div>

          <form class="wb-toolbar" action="/workbench/issues" method="get">
            <label class="wb-label" for="q">筛选</label>
            <input id="q" class="wb-input" type="search" name="q" value={@filters["q"]} placeholder="标题或编号" />
            <button class="wb-btn" type="submit">应用</button>
          </form>

          <div class="wb-segmented" role="group" aria-label="显示方式">
            <a href={path_for(@filters, "view", "board")} aria-selected={@filters["view"] != "list"}>看板</a>
            <a href={path_for(@filters, "view", "list")} aria-selected={@filters["view"] == "list"}>列表</a>
          </div>

          <button class="wb-btn wb-btn-primary" phx-click="toggle-create" type="button">新建 Issue</button>
        </div>
      </:toolbar>

      <section :if={@create_open} class="wb-panel" aria-label="新建 Issue">
        <h2 class="wb-section-title">新建 Issue</h2>
        <p class="wb-muted">
          状态与负责人来自当前 provider，不在界面里硬编码选项。
        </p>

        <form phx-submit="create" phx-change="create-draft">
          <div class="wb-field">
            <label class="wb-label" for="new-title">标题</label>
            <input id="new-title" class="wb-input" name="issue[title]" value={@create_draft["title"]} required />
          </div>

          <div class="wb-field">
            <label class="wb-label" for="new-description">描述</label>
            <textarea id="new-description" class="wb-textarea" name="issue[description]">{@create_draft["description"]}</textarea>
          </div>

          <div class="wb-field">
            <label class="wb-label" for="new-state">原生状态</label>
            <select id="new-state" class="wb-select" name="issue[native_state]" required>
              <option
                :for={state <- @state_options}
                value={state.name}
                selected={@create_draft["native_state"] == state.name}
              >
                {state.name}
              </option>
            </select>
          </div>

          <div class="wb-field">
            <label class="wb-label" for="new-assignee">负责人</label>
            <select id="new-assignee" class="wb-select" name="issue[assignee_id]">
              <option value="">不指派</option>
              <option
                :for={assignee <- @assignees}
                value={assignee.id}
                selected={@create_draft["assignee_id"] == assignee.id}
              >
                {assignee.name}
              </option>
            </select>
          </div>

          <button class="wb-btn wb-btn-primary" type="submit" disabled={@submitting}>
            {if @submitting, do: "提交中…", else: "创建"}
          </button>
          <button class="wb-btn" type="button" phx-click="toggle-create">取消</button>
        </form>
      </section>

      <p :if={@load_error} class="wb-banner wb-banner-error" role="alert">{@load_error}</p>

      <p :if={@items == [] and !@load_error} class="wb-panel wb-banner-empty">
        当前筛选没有匹配的 Issue。筛选可清空，或换一个状态再试。
      </p>

      <div :if={@filters["view"] == "list"} class="wb-panel">
        <table class="wb-table">
          <caption>共 {@issue_count} 个 Issue</caption>
          <thead>
            <tr>
              <th scope="col">编号</th>
              <th scope="col">标题</th>
              <th scope="col">原生状态</th>
              <th scope="col">显示列</th>
              <th scope="col">负责人</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={issue <- @items}>
              <td><a href={"/workbench/issues/" <> issue["identifier"]}>{issue["identifier"]}</a></td>
              <td>{issue["title"]}</td>
              <td>{issue["native_state"]}</td>
              <td>{issue["display_column"]}</td>
              <td>{issue["assignee"] || "未指派"}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@filters["view"] != "list"} class="wb-board">
        <WorkbenchComponents.column
          :for={{column, issues} <- @columns}
          column={column}
          issues={issues}
          total={@column_counts[column] || 0}
        />
      </div>
    </WorkbenchComponents.shell>

    <section :if={@unavailable} class="wb-main">
      <h1 class="wb-title">工作台未启用</h1>
      <p class="wb-banner wb-banner-warning">
        当前 WORKFLOW.md 没有启用 workbench 段（{inspect(@unavailable)}）。原运行状态页仍然可用。
      </p>
      <p><a href="/">查看运行状态</a></p>
    </section>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Data
  # ------------------------------------------------------------------

  defp load_board(socket) do
    project = socket.assigns.project
    params = socket.assigns.filters

    socket
    |> assign(:pending, socket.assigns[:pending] || new_key())
    |> assign_metadata(project)
    |> load_issues(project, params)
  end

  defp assign_metadata(socket, project) do
    case Query.provider_metadata(project) do
      {:ok, metadata} ->
        assign(socket,
          state_options: Enum.map(metadata["states"], &%{name: &1.name, active: &1.active, terminal: &1.terminal}),
          assignees: metadata["assignees"]
        )

      {:error, _code, _details} ->
        assign(socket, state_options: [], assignees: [])
    end
  end

  defp load_issues(socket, project, params) do
    case Query.list_issues(project, params) do
      {:ok, %{items: items}} ->
        column_counts = counts_for(items, project)

        assign(socket,
          items: items,
          columns: group_by_column(items, project.display_states),
          column_counts: column_counts,
          issue_count: length(items),
          load_error: nil,
          snapshot: snapshot(project)
        )

      {:error, code, details} ->
        assign(socket,
          items: [],
          columns: Enum.map(project.display_states, &{&1, []}),
          column_counts: %{},
          issue_count: 0,
          snapshot: nil,
          load_error: "读取 Issue 失败：#{code} #{inspect(details)}"
        )
    end
  end

  # Counted from the page that is actually on screen, so a header count can
  # never disagree with the cards under it and no second provider read is made.
  defp counts_for(items, project) do
    counts = items |> Enum.map(& &1["display_column"]) |> Enum.frequencies()
    columns = Enum.uniq(project.display_states ++ Map.keys(counts))

    Map.new(columns, &{&1, Map.get(counts, &1, 0)})
  end

  defp group_by_column(items, display_states) do
    grouped = Enum.group_by(items, & &1["display_column"])

    columns =
      (display_states ++ Map.keys(grouped))
      |> Enum.uniq()
      |> Enum.filter(fn column -> Map.get(grouped, column, []) != [] or column in display_states end)

    Enum.map(columns, fn column -> {column, Map.get(grouped, column, [])} end)
  end

  defp snapshot(project) do
    {:ok, snapshot} = Query.snapshot(project, runtime_snapshot: runtime_snapshot(project))
    snapshot
  end

  # Demonstration payloads declare their own runtime counts so the board can
  # show the fixture honestly. They are never used in live mode, where the
  # scheduler is the only source of running counts.
  defp runtime_snapshot(%Project{mode: "demo"}) do
    counts = DemoAdapter.demo().display["runtime_counts"] || %{}

    fn -> %{running_count: counts["running"] || 0, paused_count: counts["paused"] || 0} end
  end

  defp runtime_snapshot(_project), do: nil

  defp summary(snapshot) do
    "#{snapshot["issue_count"]} 个 Issue · #{snapshot["running_count"]} 个任务运行中 · #{snapshot["review_count"]} 项待审阅"
  end

  defp demo_notice(%Project{mode: "demo"}), do: DemoAdapter.notice()
  defp demo_notice(_project), do: nil

  defp path_for(filters, key, value) do
    filters
    |> Map.put(key, value)
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> URI.encode_query()
    |> then(&"/workbench/issues?#{&1}")
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # A refused create keeps what was typed; an accepted one starts clean.
  defp next_draft(socket, operation) do
    if WorkbenchComponents.applied?(operation), do: empty_draft(), else: socket.assigns.create_draft
  end

  defp empty_draft do
    %{"title" => "", "description" => "", "native_state" => "", "assignee_id" => ""}
  end

  defp new_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp local_actor do
    %{kind: "human", id: "local-operator", display_name: "本机操作者"}
  end
end
