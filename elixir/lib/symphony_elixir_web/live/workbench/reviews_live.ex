defmodule SymphonyElixirWeb.Workbench.ReviewsLive do
  @moduledoc """
  Scheme review: what was proposed, what the trade-offs are, and what a human
  decided.

  The page reads decisions and reviews from the store and submits changes
  through `Experience.Operations`, so "a candidate was selected", "a decision
  was recorded", "the workflow was updated" and "the executor loaded it" stay
  four different facts.
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
           decisions: [],
           reviews: [],
           selected_option: nil,
           constraints: "",
           resume_after_apply: false,
           resume_target_state: "",
           form_error: nil,
           receipt: nil,
           load_error: nil,
           pending: new_key()
         )}

      {:error, code, details} ->
        {:ok, assign(socket, unavailable: {code, details})}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:project] do
      {:noreply, socket |> assign(:decision_id, params["decision_id"]) |> load()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select-option", %{"option_id" => option_id}, socket) do
    # Selecting a candidate is a *client* choice; it writes nothing.
    {:noreply, assign(socket, selected_option: option_id, form_error: nil)}
  end

  def handle_event("constraints", %{"constraints" => %{"body" => body}}, socket) do
    {:noreply, assign(socket, constraints: body)}
  end

  def handle_event("toggle-resume", _params, socket) do
    {:noreply, assign(socket, resume_after_apply: not socket.assigns.resume_after_apply)}
  end

  def handle_event("resume-target", %{"resume" => %{"target_state" => target}}, socket) do
    {:noreply, assign(socket, resume_target_state: target)}
  end

  def handle_event("adopt", %{"adopt" => attrs}, socket) do
    decision = socket.assigns.decision
    option_id = attrs["option_id"] || socket.assigns.selected_option

    request = %{
      action: "adopt_decision",
      idempotency_key: socket.assigns.pending,
      expected_revision: socket.assigns.decision_revision,
      payload: %{
        "issue_id" => decision["issue_id"],
        "provider_version" => attrs["provider_version"] || "",
        "decision_id" => decision["id"],
        "option_id" => option_id,
        "resume_after_apply" => socket.assigns.resume_after_apply,
        "resume_target_state" => blank_to_nil(socket.assigns.resume_target_state)
      }
    }

    {:noreply, submit(socket, request)}
  end

  def handle_event("adjust-constraints", %{"constraints" => %{"body" => body}}, socket) do
    request = %{
      action: "adjust_constraints",
      idempotency_key: socket.assigns.pending,
      expected_revision: socket.assigns.decision_revision,
      payload: %{
        "issue_id" => socket.assigns.decision["issue_id"],
        "provider_version" => "",
        "decision_id" => socket.assigns.decision["id"],
        "constraints" => split_constraints(body),
        "resume_after_apply" => false,
        "resume_target_state" => nil
      }
    }

    {:noreply, submit(socket, request)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <WorkbenchComponents.shell
        :if={!@unavailable}
        active="/workbench/reviews"
        project_id={@project.project_id}
        notice={demo_notice(@project)}
        error={@form_error}
      >
        <:toolbar>
          <div class="wb-page-head">
            <h1 class="wb-title">审阅记录</h1>
            <p class="wb-subtitle">{@decisions |> length()} 个方案决定 · {@reviews |> length()} 条审阅意见</p>
          </div>
        </:toolbar>

        <p :if={@load_error} class="wb-banner wb-banner-error" role="alert">{@load_error}</p>

        <section :if={!@decision} class="wb-panel">
          <h2 class="wb-section-title">方案决定</h2>
          <p :if={@decisions == []} class="wb-muted">
            还没有记录到方案决定。执行器上报的草稿决定会出现在这里。
          </p>
          <table :if={@decisions != []} class="wb-table">
            <caption>选择一项查看取舍与采用回执</caption>
            <thead>
              <tr>
                <th scope="col">决定</th>
                <th scope="col">状态</th>
                <th scope="col">计划修订</th>
                <th scope="col">已选方案</th>
                <th scope="col">关联 Issue</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={decision <- @decisions}>
                <td>
                  <a href={"/workbench/reviews/" <> decision["id"]}>{decision["id"]}</a>
                </td>
                <td>{decision["status"]}</td>
                <td class="wb-mono">{decision["plan_revision"]}</td>
                <td>{decision["selected_option_id"] || "—"}</td>
                <td>{decision["issue_id"]}</td>
              </tr>
            </tbody>
          </table>

          <h2 class="wb-section-title">审阅意见</h2>
          <p :if={@reviews == []} class="wb-muted">还没有审阅意见。</p>
          <ul class="wb-list">
            <li :for={review <- @reviews} class="wb-card">
              <p>
                <strong>{review["verdict"] || review["action"]}</strong>
                · {review["target_type"]} {review["target_id"]}
              </p>
              <p class="wb-muted">{review["body"]}</p>
            </li>
          </ul>
        </section>

        <section :if={@decision} class="wb-split wb-split-64-36">
          <article class="wb-panel">
            <p class="wb-muted"><a href="/workbench/reviews">审阅记录</a> / {@decision["id"]}</p>

            <h2 class="wb-section-title">方案取舍</h2>
            <form phx-submit="adopt">
              <div class="wb-field">
                <p class="wb-muted">
                  选中只是候选：采用前不会写任何东西，采用后按工作流更新计划。
                </p>

                <div class="wb-check" :for={option <- @decision["options"]}>
                  <input
                    type="radio"
                    id={"option-" <> option["id"]}
                    name="adopt[option_id]"
                    value={option["id"]}
                    checked={@selected_option == option["id"]}
                    phx-click="select-option"
                    phx-value-option_id={option["id"]}
                  />
                  <label for={"option-" <> option["id"]}>
                    <strong>{option["id"]} · {option["title"]}</strong>
                    <span class="wb-muted">{option["proposal"]}</span>
                    <span :for={tradeoff <- option["tradeoffs"]} class="wb-pill">{tradeoff}</span>
                    <span :if={option["remaining_validation"] != []} class="wb-muted">
                      尚需验证：{Enum.join(option["remaining_validation"], "；")}
                    </span>
                  </label>
                </div>
              </div>

              <p :if={@selected_option} class="wb-banner wb-banner-warning">
                将采用方案 {@selected_option}；这只是候选选择，提交后才会记录决定。
              </p>
              <p :if={!@selected_option} class="wb-muted">先选择一个候选方案。</p>

              <div class="wb-field">
                <label class="wb-label" for="provider-version">provider 版本（采用前乐观检查）</label>
                <input id="provider-version" class="wb-input" name="adopt[provider_version]" value={@decision_provider_version} />
              </div>

              <div class="wb-check">
                <input
                  type="checkbox"
                  id="resume-after-apply"
                  checked={@resume_after_apply}
                  phx-click="toggle-resume"
                />
                <label for="resume-after-apply">采用后恢复执行（默认不恢复）</label>
              </div>

              <div :if={@resume_after_apply} class="wb-field">
                <label class="wb-label" for="resume-target">恢复到的原生状态</label>
                <input
                  id="resume-target"
                  class="wb-input"
                  name="resume[target_state]"
                  value={@resume_target_state}
                  phx-change="resume-target"
                />
              </div>

              <button class="wb-btn wb-btn-primary" type="submit" disabled={!@selected_option}>采用方案</button>
            </form>

            <h2 class="wb-section-title">我的约束</h2>
            <form phx-submit="adjust-constraints" phx-change="constraints">
              <div class="wb-field">
                <label class="wb-label" for="constraints-body">每行一条；对已采用的方案修改会创建新的采用修订</label>
                <textarea id="constraints-body" class="wb-textarea" name="constraints[body]">{@constraints}</textarea>
              </div>
              <button class="wb-btn" type="submit">保存约束</button>
            </form>
          </article>

          <aside class="wb-panel">
            <h2 class="wb-section-title">决定状态</h2>
            <dl class="wb-dl">
              <dt>状态</dt>
              <dd>{@decision["status"]}</dd>
              <dt>计划修订</dt>
              <dd class="wb-mono">{@decision["plan_revision"]}</dd>
              <dt>本地修订</dt>
              <dd class="wb-mono">{@decision_revision}</dd>
              <dt>关联 Issue</dt>
              <dd class="wb-mono">{@decision["issue_id"]}</dd>
            </dl>

            <p :if={@decision["limitations"] != []} class="wb-banner wb-banner-warning">
              限制：{Enum.join(@decision["limitations"], "；")}
            </p>

            <h2 class="wb-section-title">执行回执</h2>
            <p :if={!@receipt} class="wb-muted">还没有提交过操作。</p>
            <ul :if={@receipt} class="wb-list">
              <li class="wb-card">
                <p><strong>{@receipt["action"]}</strong> · {@receipt["status"]}</p>
                <ul class="wb-list">
                  <li :for={step <- @receipt["steps"]} class="wb-muted">
                    {step["name"]}：{step["status"]} — {step["detail"]}
                  </li>
                </ul>
              </li>
            </ul>

            <h2 class="wb-section-title">相关记录</h2>
            <ul class="wb-list">
              <li :for={case_id <- @decision["problem_case_ids"]} class="wb-muted">问题分析 {case_id}</li>
            </ul>
          </aside>
        </section>
      </WorkbenchComponents.shell>

      <section :if={@unavailable} class="wb-main">
        <h1 class="wb-title">工作台未启用</h1>
        <p class="wb-banner wb-banner-warning">{inspect(@unavailable)}</p>
      </section>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Data
  # ------------------------------------------------------------------

  defp load(socket) do
    project = socket.assigns.project

    case socket.assigns.decision_id do
      nil ->
        assign(socket,
          decision: nil,
          decision_revision: nil,
          decision_provider_version: "",
          decisions: entities(project, "Decision"),
          reviews: entities(project, "Review"),
          load_error: nil
        )

      decision_id ->
        case Query.get_entity(project, "Decision", decision_id) do
          {:ok, decision} ->
            assign(socket,
              decision: decision,
              decision_revision: decision["revision"],
              decision_provider_version: decision["provider_version"] || "",
              selected_option: decision["selected_option_id"],
              constraints: Enum.join(decision["constraints"] || [], "\n"),
              decisions: entities(project, "Decision"),
              reviews: entities(project, "Review"),
              load_error: nil
            )

          {:error, _code, _details} ->
            assign(socket, decision: nil, decisions: [], reviews: [], load_error: "找不到决定 #{decision_id}。")
        end
    end
  end

  defp entities(project, type) do
    case Query.list_entities(project, type) do
      {:ok, records} -> Enum.map(records, &entity_wire/1)
      _error -> []
    end
  end

  defp entity_wire(record) do
    record.payload
    |> Map.put("id", record.entity_id)
    |> Map.put("revision", record.entity_revision)
  end

  defp submit(socket, request) do
    case Operations.submit(socket.assigns.project, local_actor(), request) do
      {:ok, operation} ->
        socket
        |> assign(
          receipt: operation,
          form_error: WorkbenchComponents.receipt_warning(operation)
        )
        |> assign(:pending, if(WorkbenchComponents.applied?(operation), do: new_key(), else: socket.assigns.pending))
        |> load()

      {:error, code, details} ->
        assign(socket, form_error: "提交失败：#{code} #{inspect(details)}")
    end
  end

  defp split_constraints(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp demo_notice(%Project{mode: "demo"}), do: DemoAdapter.notice()
  defp demo_notice(_project), do: nil

  defp new_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp local_actor do
    %{kind: "human", id: "local-operator", display_name: "本机操作者"}
  end
end
