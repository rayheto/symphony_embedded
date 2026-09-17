defmodule SymphonyElixirWeb.Workbench.IssueDetailLive do
  @moduledoc """
  One issue: what it is, what the executor reported, and what was recorded.

  The page reads through `Experience.Query` only. It never infers engineering
  facts from the board: a plan, a case or an evidence item appears here because
  the store holds it, not because a card moved.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :workbench}

  alias SymphonyElixir.Experience.{DemoAdapter, Operations, Project, Query}
  alias SymphonyElixirWeb.WorkbenchComponents

  @tabs ~w(overview activity investigation changes)

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    case Project.load() do
      {:ok, project} ->
        {:ok,
         assign(socket,
           project: project,
           identifier: identifier,
           tab: "overview",
           view: nil,
           context: %{},
           changes: %{},
           events: [],
           operations: [],
           problem_cases: [],
           evidence: [],
           validations: [],
           native_url?: false,
           load_error: nil,
           unavailable: nil,
           comment: "",
           form_error: nil,
           submitting: false,
           pending: nil
         )}

      {:error, code, details} ->
        {:ok,
         assign(socket,
           unavailable: {code, details},
           identifier: identifier,
           tab: "overview",
           project: nil,
           view: nil,
           context: %{},
           changes: %{},
           events: [],
           operations: [],
           problem_cases: [],
           evidence: [],
           validations: [],
           native_url?: false,
           comment: "",
           form_error: nil,
           submitting: false,
           pending: nil,
           load_error: nil
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:project] do
      {:noreply, socket |> assign(:tab, normalize_tab(params["tab"])) |> load_issue()}
    else
      {:noreply, socket}
    end
  end

  @doc false
  @impl true
  def handle_event("draft", %{"comment" => %{"body" => body}}, socket) do
    # Keep the unsent text in the socket so a failed send never eats the input.
    {:noreply, assign(socket, :comment, body)}
  end

  @impl true
  def handle_event("comment", %{"comment" => %{"body" => body}}, socket) do
    request = %{
      action: "comment",
      idempotency_key: socket.assigns.pending,
      expected_revision: nil,
      payload: %{
        "issue_id" => socket.assigns.view.id,
        "target_type" => "issue",
        "target_id" => socket.assigns.view.id,
        "body" => body
      }
    }

    case Operations.submit(socket.assigns.project, local_actor(), request) do
      {:ok, operation} ->
        # The typed text is only cleared once the provider confirmed it; a
        # refused comment must not eat what the operator wrote.
        {:noreply,
         socket
         |> assign(
           comment: if(WorkbenchComponents.applied?(operation), do: "", else: socket.assigns.comment),
           submitting: false,
           form_error: WorkbenchComponents.receipt_warning(operation),
           pending: new_key()
         )
         |> load_issue()}

      {:error, code, details} ->
        # The typed text stays in the box: a failed send must not eat the input.
        {:noreply, socket |> assign(submitting: false, form_error: "发送失败：#{code} #{inspect(details)}")}
    end
  end

  @impl true
  def handle_event("request-evidence", _params, socket) do
    request = %{
      action: "request_evidence",
      idempotency_key: socket.assigns.pending,
      expected_revision: nil,
      payload: %{
        "issue_id" => socket.assigns.view.id,
        "target_type" => "issue",
        "target_id" => socket.assigns.view.id,
        "question" => socket.assigns.comment
      }
    }

    case Operations.submit(socket.assigns.project, local_actor(), request) do
      {:ok, operation} ->
        {:noreply,
         socket
         |> assign(
           comment: if(WorkbenchComponents.applied?(operation), do: "", else: socket.assigns.comment),
           form_error: WorkbenchComponents.receipt_warning(operation),
           pending: new_key()
         )
         |> load_issue()}

      {:error, code, details} ->
        {:noreply, assign(socket, form_error: "请求失败：#{code} #{inspect(details)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <WorkbenchComponents.shell
        :if={!@unavailable and @view}
        active="/workbench/issues"
        project_id={@project.project_id}
        notice={demo_notice(@project)}
        error={@form_error}
      >
        <:toolbar>
          <p class="wb-muted">
            <a href="/workbench/issues">Issues</a> / {@view.identifier}
          </p>

          <div class="wb-page-head">
            <h1 class="wb-title">{@view.title}</h1>
            <div class="wb-spacer"></div>
            <WorkbenchComponents.state_badge column={@view.display_column} />
            <a :if={@native_url?} class="wb-btn" href={@view.url} rel="noreferrer noopener" target="_blank">打开原工单</a>
            <span :if={!@native_url?} class="wb-muted">当前 provider 未提供原生链接</span>
          </div>

          <dl class="wb-dl">
            <dt>原生状态</dt>
            <dd>{@view.native_state}</dd>
            <dt>负责人</dt>
            <dd>{@view.assignee || "未指派"}</dd>
            <dt>标签</dt>
            <dd>{Enum.join(@view.labels, "、")}</dd>
          </dl>
        </:toolbar>

        <nav class="wb-tabs" aria-label="Issue 视图">
          <a
            :for={tab <- tabs()}
            class="wb-tab"
            href={"/workbench/issues/#{@view.identifier}?tab=#{tab}"}
            aria-selected={@tab == tab}
          >
            {tab_label(tab)}
          </a>
        </nav>

        <section :if={@tab == "overview"} class="wb-split wb-split-60-40">
          <article class="wb-panel">
            <h2 class="wb-section-title">描述</h2>
            <p>{@view.description || "该 Issue 没有描述。"}</p>

            <h2 class="wb-section-title">当前计划引用</h2>
            <p :if={!@context["current_plan"]} class="wb-muted">
              该 Issue 还没有已采用的计划引用。
            </p>
            <dl :if={@context["current_plan"]} class="wb-dl">
              <dt>决定</dt>
              <dd class="wb-mono">{@context["current_plan"]["decision_id"] || "—"}</dd>
              <dt>计划修订</dt>
              <dd class="wb-mono">{@context["current_plan"]["plan_revision"]}</dd>
              <dt>计划摘要</dt>
              <dd class="wb-mono">{@context["current_plan"]["plan_sha256"]}</dd>
              <dt>读取时间</dt>
              <dd>{@context["current_plan"]["observed_at"]}</dd>
            </dl>
          </article>

          <aside class="wb-panel">
            <h2 class="wb-section-title">相关工作台记录</h2>
            <ul class="wb-list">
              <li><a href={issue_link(@view.identifier, "investigation")}>问题分析 {@context["problem_case_ids"] |> length()} 条</a></li>
              <li><a href={issue_link(@view.identifier, "investigation")}>证据 {@context["evidence_ids"] |> length()} 条</a></li>
              <li><a href={issue_link(@view.identifier, "activity")}>决定 {@context["decision_ids"] |> length()} 条</a></li>
            </ul>
            <p class="wb-muted">
              运行详情仍使用原 runtime 视图：<a href={@context["runtime_snapshot_url"]}>/@ view.identifier</a>
            </p>
          </aside>
        </section>

        <section :if={@tab == "activity"} class="wb-panel">
          <h2 class="wb-section-title">活动记录</h2>
          <p :if={@events == []} class="wb-muted">该 Issue 还没有记录到的工程事件。</p>
          <ol class="wb-timeline">
            <li :for={event <- @events}>
              <time datetime={event["recorded_at"]}>{event["recorded_at"]}</time>
              <p>{event["type"]} · {event["entity_type"]} {event["entity_id"]}</p>
              <p class="wb-muted">{event["payload"]["detail"]}</p>
            </li>
          </ol>

          <h2 class="wb-section-title">操作回执</h2>
          <p :if={@operations == []} class="wb-muted">没有针对该 Issue 的操作。</p>
          <ul class="wb-list">
            <li :for={operation <- @operations} class="wb-card">
              <p><strong>{operation["action"]}</strong> · {operation["status"]}</p>
              <ul class="wb-list">
                <li :for={step <- operation["steps"]} class="wb-muted">
                  {step["name"]}：{step["status"]} — {step["detail"]}
                </li>
              </ul>
            </li>
          </ul>
        </section>

        <section :if={@tab == "investigation"} class="wb-split wb-split-60-40">
          <article class="wb-panel">
            <h2 class="wb-section-title">问题分析</h2>
            <p :if={@problem_cases == []} class="wb-muted">还没有问题分析记录。</p>

            <article :for={problem <- @problem_cases} class="wb-card">
              <p><strong>{problem["symptom"]}</strong></p>
              <p class="wb-muted">当前判断：{problem["current_conclusion"] || "尚无结论"}</p>
              <p class="wb-muted">下一步：{problem["next_step"] || "未记录"}</p>

              <h3 class="wb-section-title">假设</h3>
              <ul class="wb-list">
                <li :for={claim <- problem["claims"]}>
                  <span class="wb-pill">{claim["status"]}</span>
                  {claim["statement"]}
                  <span :if={claim["evidence_missing"]} class="wb-muted">（缺少证据）</span>
                </li>
              </ul>

              <h3 class="wb-section-title">实验</h3>
              <ul class="wb-list">
                <li :for={experiment <- problem["experiments"]}>
                  <time datetime={experiment["occurred_at"]}>{experiment["occurred_at"]}</time>
                  <p>{experiment["question"]} → {experiment["outcome"]}</p>
                  <p class="wb-muted">{experiment["observation"]}</p>
                </li>
              </ul>

              <p :if={problem["limitations"] != []} class="wb-banner wb-banner-warning">
                限制：{Enum.join(problem["limitations"], "；")}
              </p>
            </article>

            <h2 class="wb-section-title">验收记录</h2>
            <p :if={@validations == []} class="wb-muted">还没有针对这些假设的验收记录。</p>

            <article :for={validation <- @validations} class="wb-card">
              <p>
                <span class="wb-pill">{validation["result"]}</span>
                {validation["criteria"]}
              </p>
              <p class="wb-muted">
                判据版本 {validation["criteria_revision"]} · 执行时间 {validation["executed_at"] || "未执行"}
              </p>
              <p :if={validation["limitations"] != []} class="wb-muted">
                限制：{Enum.join(validation["limitations"], "；")}
              </p>
            </article>
          </article>

          <aside class="wb-panel">
            <h2 class="wb-section-title">证据</h2>
            <p :if={@evidence == []} class="wb-muted">还没有证据记录。</p>
            <ul class="wb-list">
              <li :for={item <- @evidence} class="wb-card">
                <p><strong>{item["title"]}</strong></p>
                <p class="wb-muted">
                  来源 {item["source_kind"]} · 内容 {item["content_status"]} · 人工审阅 {item["review_status"]}
                </p>
                <p class="wb-muted">
                  采集时间 {item["captured_at"] || "未知"} · 接收时间 {item["received_at"]}
                </p>
                <p :if={item["limitations"] != []} class="wb-muted">
                  限制：{Enum.join(item["limitations"], "；")}
                </p>
              </li>
            </ul>

            <h2 class="wb-section-title">意见与约束</h2>
            <form phx-submit="comment" phx-change="draft">
              <div class="wb-field">
                <label class="wb-label" for="comment-body">添加意见（默认只是意见，不会改变执行方向）</label>
                <textarea id="comment-body" class="wb-textarea" name="comment[body]" required>{@comment}</textarea>
              </div>
              <button class="wb-btn" type="submit">发送意见</button>
              <button class="wb-btn" type="button" phx-click="request-evidence">要求补充证据</button>
            </form>
            <p class="wb-muted">要求补充证据会先记录请求；非 active 的 Issue 不会因此自动恢复执行。</p>

            <h2 class="wb-section-title">操作回执</h2>
            <p :if={@operations == []} class="wb-muted">没有针对该 Issue 的操作。</p>
            <ul class="wb-list">
              <li :for={operation <- @operations} class="wb-card">
                <p><strong>{operation["action"]}</strong> · {operation["status"]}</p>
                <p class="wb-muted">{operation["steps"] |> hd() |> Map.get("detail")}</p>
              </li>
            </ul>
          </aside>
        </section>

        <section :if={@tab == "changes"} class="wb-panel">
          <h2 class="wb-section-title">变更范围</h2>
          <p class="wb-banner wb-banner-warning">
            状态：{@changes["status"]}。{@changes["limitations"] |> Enum.join("；")}
          </p>
          <p class="wb-muted">读取到变更后才能显示 diff；这里不会用推测的内容填充。</p>
        </section>
      </WorkbenchComponents.shell>

      <section :if={@unavailable} class="wb-main">
        <h1 class="wb-title">工作台未启用</h1>
        <p class="wb-banner wb-banner-warning">{inspect(@unavailable)}</p>
      </section>

      <section :if={@load_error} class="wb-main">
        <h1 class="wb-title">找不到该 Issue</h1>
        <p class="wb-banner wb-banner-error">{@load_error}</p>
        <p><a href="/workbench/issues">返回 Issues</a></p>
      </section>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Data
  # ------------------------------------------------------------------

  defp load_issue(socket) do
    project = socket.assigns.project
    identifier = socket.assigns.identifier

    case Query.get_issue(project, identifier) do
      {:ok, view} ->
        socket
        |> assign(
          view: view,
          load_error: nil,
          pending: socket.assigns[:pending] || new_key(),
          native_url?: Enum.any?(view.capabilities, &(&1.name == "native_url" and &1.available))
        )
        |> assign_related(project, view)

      {:error, code, details} ->
        assign(socket,
          view: nil,
          load_error: "读取 Issue 失败：#{code} #{inspect(details)}",
          context: %{},
          changes: %{},
          events: [],
          operations: [],
          problem_cases: [],
          evidence: [],
          validations: []
        )
    end
  end

  defp assign_related(socket, project, view) do
    context = Query.context_for(project, view)
    {:ok, changes} = Query.changes_for(project, view)

    # A case is what ties the rest of the engineering record to the issue: it
    # names the issue, its claims name the evidence they rest on, and a
    # validation names the claim it decided. Evidence and validations carry no
    # back-reference to an issue in the contract, so the chain is followed
    # rather than guessed.
    problem_cases = ids_to_entities(project, "ProblemCase", context)
    evidence = issue_evidence(project, context, problem_cases)
    validations = issue_validations(project, problem_cases)
    related = problem_cases ++ evidence ++ validations

    assign(socket,
      context: context,
      changes: changes,
      events: issue_events(project, view, context, problem_cases, related),
      operations: Operations.list(project, %{issue_id: view.id}),
      problem_cases: problem_cases,
      evidence: evidence,
      validations: validations
    )
  end

  # An engineering event names the record it is about, so the issue timeline is
  # the union of events about the issue itself, about the records the page found
  # through the case chain, and about the claims that chain rests on.
  defp issue_events(project, view, context, problem_cases, related) do
    known = related_entity_ids(view, context, problem_cases, related)

    case Query.events(project, %{limit: 500}) do
      {:ok, page} -> Enum.filter(page["items"], &MapSet.member?(known, &1["entity_id"]))
      _error -> []
    end
  end

  defp related_entity_ids(view, context, problem_cases, related) do
    ids =
      Map.get(context, "problem_case_ids", []) ++
        Map.get(context, "evidence_ids", []) ++
        Map.get(context, "decision_ids", []) ++
        claim_ids(problem_cases) ++
        Enum.map(related, & &1["id"])

    MapSet.new([view.id | ids])
  end

  defp claim_ids(problem_cases) do
    for problem <- problem_cases, claim <- List.wrap(problem["claims"]), do: claim["id"]
  end

  # Both directions count: a claim that rests on a fragment and a claim the
  # fragment refutes are both about that fragment.
  defp cited_evidence_ids(problem_cases) do
    for problem <- problem_cases,
        claim <- List.wrap(problem["claims"]),
        id <-
          List.wrap(claim["supporting_evidence_ids"]) ++ List.wrap(claim["contradicting_evidence_ids"]),
        do: id
  end

  # Reads the stored records once and keeps the ones the context named, so a
  # record that disappeared cannot be mistaken for one that was never there.
  defp ids_to_entities(project, type, context) do
    wanted = MapSet.new(Map.get(context, type_key(type), []))
    list_entities(project, type, &MapSet.member?(wanted, &1.entity_id))
  end

  # A validation decides a claim, not an issue: the anchor the store holds is
  # `claim_id`, so the issue's validations are the ones whose claim belongs to a
  # problem case of this issue. A case with no claims still asks, so a store
  # that cannot answer is reported the same way everywhere on the page.
  defp issue_validations(project, problem_cases) do
    wanted = MapSet.new(claim_ids(problem_cases))
    list_entities(project, "Validation", &MapSet.member?(wanted, &1.payload["claim_id"]))
  end

  # The record's own reference and the claims that cite it are both ways an
  # evidence item belongs to the issue; either is enough to show it.
  defp issue_evidence(project, context, problem_cases) do
    wanted = MapSet.new(Map.get(context, "evidence_ids", []) ++ cited_evidence_ids(problem_cases))
    list_entities(project, "Evidence", &MapSet.member?(wanted, &1.entity_id))
  end

  defp list_entities(project, type, keep?) do
    case Query.list_entities(project, type) do
      {:ok, records} -> records |> Enum.filter(keep?) |> Enum.map(&entity_wire/1)
      _error -> []
    end
  end

  defp entity_wire(record) do
    record.payload
    |> Map.put("id", record.entity_id)
    |> Map.put("revision", record.entity_revision)
  end

  defp type_key("ProblemCase"), do: "problem_case_ids"

  @doc "The detail tabs, in display order."
  @spec tabs() :: [String.t()]
  def tabs, do: @tabs

  defp normalize_tab(tab) when tab in @tabs, do: tab
  defp normalize_tab(_tab), do: "overview"

  defp tab_label("overview"), do: "概览"
  defp tab_label("activity"), do: "活动"
  defp tab_label("investigation"), do: "调查与证据"
  defp tab_label("changes"), do: "变更"

  defp issue_link(identifier, tab), do: "/workbench/issues/#{identifier}?tab=#{tab}"

  defp demo_notice(%Project{mode: "demo"}), do: DemoAdapter.notice()
  defp demo_notice(_project), do: nil

  defp new_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp local_actor do
    %{kind: "human", id: "local-operator", display_name: "本机操作者"}
  end
end
