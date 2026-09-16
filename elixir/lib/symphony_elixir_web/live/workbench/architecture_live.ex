defmodule SymphonyElixirWeb.Workbench.ArchitectureLive do
  @moduledoc """
  The managed project's architecture, as delivered and as checked.

  The page never draws an architecture and never invents one: it shows the
  artifact Archify delivered, the revision the host verified it against, the
  component index projected from engineering records, and — when a generation
  was refused — both the diagnostics and the last-good diagram that is still
  trusted. A diagram that was never generated is shown as absent, not as an
  empty picture.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :workbench}

  alias SymphonyElixir.Experience.{Architecture, Project}
  alias SymphonyElixirWeb.WorkbenchComponents

  @kinds ~w(source plan delta)

  @impl true
  def mount(_params, _session, socket) do
    case Project.load() do
      {:ok, project} ->
        {:ok,
         assign(socket,
           project: project,
           unavailable: nil,
           revisions: [],
           artifact: nil,
           index: nil,
           staleness: :unknown,
           viewer: nil,
           selected_component: nil,
           kind: "source",
           issue_id: "",
           revision: "",
           notice: nil,
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
      {:noreply, socket |> assign(:selected_id, params["artifact_id"]) |> load()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("select-component", %{"component" => component_id}, socket) do
    {:noreply, assign(socket, selected_component: component_id)}
  end

  # A refused request must not cost the operator what they typed, so the draft
  # lives in the socket rather than in the browser.
  def handle_event("draft", %{"request" => attrs}, socket) do
    {:noreply,
     assign(socket,
       kind: attrs["kind"] || "source",
       issue_id: attrs["issue_id"] || "",
       revision: attrs["source_revision"] || ""
     )}
  end

  def handle_event("request", %{"request" => attrs}, socket) do
    request =
      %{
        "kind" => attrs["kind"] || "source",
        "issue_id" => blank_to_nil(attrs["issue_id"]),
        "source_revision" => blank_to_nil(attrs["source_revision"]),
        "plan_revision" => blank_to_nil(attrs["plan_revision"]),
        "plan_sources" => split_lines(attrs["plan_sources"]),
        "idempotency_key" => socket.assigns.pending
      }

    case Architecture.request(socket.assigns.project, request) do
      {:ok, artifact} ->
        {:noreply,
         socket
         |> assign(
           notice: "已登记架构请求 #{artifact["id"]}（#{artifact["generation_status"]}）；生成仍由原 Issue 工作流上的 Archify 任务完成。",
           load_error: nil
         )
         |> load()}

      {:error, code, details} ->
        {:noreply, assign(socket, load_error: "无法登记请求：#{code} #{inspect(details)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <WorkbenchComponents.shell
        :if={!@unavailable}
        active="/workbench/architecture"
        project_id={@project.project_id}
        notice={@notice}
        error={@load_error}
      >
        <:toolbar>
          <div class="wb-page-head">
            <h1 class="wb-title">项目架构</h1>
            <p class="wb-subtitle">{summary(@revisions, @artifact)}</p>
            <div class="wb-spacer"></div>
            <button class="wb-btn" phx-click="refresh" type="button">刷新</button>
          </div>
        </:toolbar>

        <p :if={@revisions == []} class="wb-panel wb-banner-empty">
          还没有为该项目生成架构图。生成由 Archify 完成，本页只登记请求并核对产物；被管理的项目仓库与 revision
          未在本环境登记，因此这里不会出现凭空画出的图。
        </p>

        <section :if={@artifact} class="wb-split wb-split-64-36">
          <article class="wb-panel">
            <div class="wb-page-head">
              <h2 class="wb-section-title">{@artifact["id"]}</h2>
              <span class="wb-pill">{@artifact["kind"]}</span>
              <span class="wb-pill">{kind_label(@artifact["kind"])}</span>
              <span class={["wb-pill", "wb-pill-#{staleness_class(@staleness)}"]}>{staleness_label(@staleness)}</span>
              <div class="wb-spacer"></div>
              <a
                :if={@viewer}
                class="wb-btn"
                href={standalone_url(@viewer)}
                target="_blank"
                rel="noopener noreferrer"
              >
                独立打开
              </a>
            </div>

            <p class="wb-muted">
              已交付修订 {@artifact["revision"]} · 来源 revision <span class="wb-mono">{@artifact["source_revision"] || "设计材料"}</span>
            </p>

            <iframe
              :if={@viewer}
              class="wb-viewer"
              title="架构图（Archify 原生 viewer）"
              src={embed_url(@viewer)}
              sandbox={@viewer["sandbox"]}
              loading="lazy"
            ></iframe>

            <p :if={!@viewer} class="wb-muted">
              这一版没有可嵌入的 HTML（生成未成功或文件缺失），因此不显示上一版冒充当前修订。
            </p>

            <h2 class="wb-section-title">结构对比</h2>
            <p :if={compare_artifacts(@revisions) == []} class="wb-muted">
              还没有对比产物。对比由 Archify compare 生成 base/head 两个真实 revision 的差异，结构变化不等于运行影响或安全结论。
            </p>
            <ul :if={compare_artifacts(@revisions) != []} class="wb-list">
              <li :for={delta <- compare_artifacts(@revisions)} class="wb-card">
                <p>
                  <a href={"/workbench/architecture/" <> delta["id"]}>{delta["id"]}</a>
                  · <span class="wb-mono">{short(delta["base_revision"])}</span> →
                  <span class="wb-mono">{short(delta["source_revision"])}</span>
                </p>
                <p class="wb-muted">只有结构差异；不代表运行影响或安全结论。</p>
              </li>
            </ul>

            <h2 class="wb-section-title">组件索引</h2>
            <p :if={@index == nil} class="wb-muted">这一版没有可读的 manifest，无法给出组件索引。</p>
            <table :if={@index} class="wb-table">
              <caption>选中一个组件查看它的来源、Issue 与验证状态</caption>
              <thead>
                <tr>
                  <th scope="col">组件</th>
                  <th scope="col">层次</th>
                  <th scope="col">实现</th>
                  <th scope="col">验证</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={component <- @index["components"]}
                  phx-click="select-component"
                  phx-value-component={component["id"]}
                  aria-selected={@selected_component == component["id"]}
                >
                  <td>
                    <strong>{component["label"]}</strong>
                    <span class="wb-muted wb-mono">{component["id"]}</span>
                  </td>
                  <td>{Enum.join(component["layers"], " ")}</td>
                  <td>{component["implementation_status"]}</td>
                  <td>{component["verification_status"]}</td>
                </tr>
              </tbody>
            </table>

            <p :if={@index && @index["relationships"] != []} class="wb-muted">
              共 {@index["relationships"] |> length()} 条关系，全部来自随图交付的 IR。
            </p>
          </article>

          <aside class="wb-panel">
            <h2 class="wb-section-title">版本</h2>
            <ul class="wb-list">
              <li :for={revision <- @revisions}>
                <a href={"/workbench/architecture/" <> revision["id"]}>
                  {revision["id"]} · rev {revision["revision"]}
                </a>
                <span class="wb-muted">
                  {revision["generation_status"]} · {revision["source_revision"] || revision["plan_revision"] || "设计材料"}
                </span>
              </li>
            </ul>

            <h2 class="wb-section-title">检验回执</h2>
            <dl class="wb-dl">
              <dt>manifest</dt>
              <dd>{check_label(@artifact["schema_check"])}</dd>
              <dt>deliver</dt>
              <dd>{deliver_label(@artifact["generation_status"])}</dd>
              <dt>浏览器证据</dt>
              <dd>{check_label(@artifact["browser_check"])}</dd>
              <dt>独立视觉审阅</dt>
              <dd>{check_label(@artifact["visual_review"])}</dd>
            </dl>
            <p :if={@artifact["skill_commit"]} class="wb-muted wb-mono">
              skill {short(@artifact["skill_commit"])}
            </p>

            <p :if={@artifact["stale"] || @staleness == :stale} class="wb-banner wb-banner-warning">
              这一版不是当前 revision 的图；它描述的是
              {short(@artifact["source_revision"] || @artifact["plan_revision"] || @artifact["id"])}。
            </p>

            <h2 class="wb-section-title">限制</h2>
            <p :if={@artifact["limitations"] == []} class="wb-muted">没有登记额外限制。</p>
            <ul class="wb-list">
              <li :for={limitation <- @artifact["limitations"]} class="wb-muted">{limitation}</li>
            </ul>

            <h2 :if={@selected_component_view} class="wb-section-title">组件来源</h2>
            <div :if={@selected_component_view} class="wb-field">
              <dl class="wb-dl">
                <dt>组件</dt>
                <dd>{@selected_component_view["label"]}</dd>
                <dt>来源 revision</dt>
                <dd class="wb-mono">{@selected_component_view["source_revision"] || "设计材料"}</dd>
              </dl>
              <ul class="wb-list">
                <li :for={ref <- @selected_component_view["source_refs"]} class="wb-muted wb-mono">
                  {ref["locator"]}{line_suffix(ref)}
                </li>
              </ul>
              <ul class="wb-list">
                <li :for={link <- @selected_component_view["links"]["issues"]}>
                  <a :if={link["href"]} href={link["href"]}>{link["id"]}</a>
                  <span :if={!link["href"]} class="wb-mono">{link["id"]}</span>
                </li>
                <li :for={link <- @selected_component_view["links"]["problem_cases"]} class="wb-muted">
                  问题分析 <span class="wb-mono">{link["id"]}</span>
                </li>
                <li :for={link <- @selected_component_view["links"]["evidence"]} class="wb-muted">
                  证据 <span class="wb-mono">{link["id"]}</span>
                </li>
              </ul>
            </div>
            <p :if={!@selected_component_view} class="wb-muted">在上方组件索引里选择一项。</p>
          </aside>
        </section>

        <section class="wb-panel">
          <h2 class="wb-section-title">生成 / 更新</h2>
          <p class="wb-muted">
            这里只登记请求：生成仍挂在原 Issue 工作流上由 Archify 完成，工作台不新增执行循环。同一个 revision
            重复请求会被去重。
          </p>
          <form phx-submit="request" phx-change="draft">
            <div class="wb-field">
              <label class="wb-label" for="request-kind">产物类型</label>
              <select id="request-kind" class="wb-input" name="request[kind]">
                <option :for={kind <- kinds()} value={kind} selected={kind == @kind}>{kind_label(kind)}</option>
              </select>
            </div>
            <div class="wb-field">
              <label class="wb-label" for="request-issue">关联 Issue</label>
              <input id="request-issue" class="wb-input" name="request[issue_id]" value={@issue_id} />
            </div>
            <div class="wb-field">
              <label class="wb-label" for="request-revision">源码 revision（source/delta 必填，40 位 commit）</label>
              <input id="request-revision" class="wb-input" name="request[source_revision]" value={@revision} />
            </div>
            <div class="wb-field">
              <label class="wb-label" for="request-plan">计划材料来源（plan 用，每行一条）</label>
              <textarea id="request-plan" class="wb-textarea" name="request[plan_sources]"></textarea>
            </div>
            <button class="wb-btn wb-btn-primary" type="submit">登记请求</button>
          </form>
        </section>

        <section :if={failed_attempts(@revisions) != []} class="wb-panel">
          <h2 class="wb-section-title">未被采纳的尝试</h2>
          <ul class="wb-list">
            <li :for={attempt <- failed_attempts(@revisions)} class="wb-card">
              <p>
                <strong>{attempt["id"]}</strong> · rev {attempt["revision"]} · {attempt["generation_status"]}
              </p>
              <ul class="wb-list">
                <li :for={diagnostic <- attempt["diagnostics"] || []} class="wb-muted wb-mono">
                  {diagnostic["code"]}：{diagnostic["detail"]}
                </li>
              </ul>
              <p class="wb-muted">last-good 仍是 {attempt["last_good_id"] || "（无）"}。</p>
            </li>
          </ul>
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

    case Architecture.list_revisions(project) do
      {:error, code, details} ->
        assign(socket, revisions: [], artifact: nil, index: nil, load_error: "无法读取架构记录：#{code} #{inspect(details)}")

      revisions ->
        artifact = select(revisions, socket.assigns[:selected_id])

        socket
        |> assign(
          revisions: revisions,
          artifact: artifact,
          load_error: nil
        )
        |> assign_artifact(artifact)
    end
  end

  defp assign_artifact(socket, nil) do
    assign(socket, index: nil, viewer: nil, staleness: :unknown, selected_component: nil, selected_component_view: nil)
  end

  defp assign_artifact(socket, artifact) do
    project = socket.assigns.project

    index =
      case Architecture.component_index(project, artifact) do
        {:ok, index} -> index
        {:error, _code, _details} -> nil
      end

    selected = socket.assigns[:selected_component] || default_component(index)

    assign(socket,
      index: index,
      viewer: viewer(project, artifact),
      staleness: Architecture.staleness(project, artifact),
      selected_component: selected,
      selected_component_view: find_component(index, selected)
    )
  end

  defp viewer(project, artifact) do
    case Architecture.read_file(project, artifact, "html") do
      {:ok, _bytes, _media} -> Architecture.viewer_descriptor(project, artifact)
      {:error, _code, _details} -> nil
    end
  end

  defp select(revisions, id) when is_binary(id) do
    Enum.find(revisions, &(&1["id"] == id)) || newest_good(revisions)
  end

  defp select(revisions, nil), do: newest_good(revisions)

  defp newest_good(revisions) do
    Enum.find(revisions, &(&1["generation_status"] == "succeeded")) || List.first(revisions)
  end

  defp failed_attempts(revisions), do: Enum.filter(revisions, &(&1["generation_status"] == "failed"))

  defp default_component(%{"components" => [component | _rest]}), do: component["id"]
  defp default_component(_index), do: nil

  defp find_component(index, id) when is_map(index) and is_binary(id) do
    Enum.find(index["components"], &(&1["id"] == id))
  end

  defp find_component(_index, _id), do: nil

  defp compare_artifacts(revisions), do: Enum.filter(revisions, &(&1["kind"] == "delta"))

  defp summary([], _artifact), do: "尚未生成架构图。"

  defp summary(revisions, artifact) do
    last_good = Enum.find(revisions, &(&1["generation_status"] == "succeeded"))

    cond do
      is_nil(last_good) -> "#{length(revisions)} 次尝试，尚无 last-good。"
      artifact && last_good["id"] == artifact["id"] -> "last-good：#{last_good["id"]} · rev #{last_good["revision"]}"
      true -> "last-good：#{last_good["id"]} · 当前显示 #{artifact["id"]}"
    end
  end

  defp staleness_label(:fresh), do: "对应当前 revision"
  defp staleness_label(:stale), do: "已过期"
  defp staleness_label(:unknown), do: "无法判断是否过期"

  defp staleness_class(:fresh), do: "ok"
  defp staleness_class(:stale), do: "review"
  defp staleness_class(:unknown), do: "warning"

  defp kind_label("source"), do: "源码图"
  defp kind_label("plan"), do: "计划图（设计材料）"
  defp kind_label("delta"), do: "对比图"
  defp check_label(nil), do: "未记录"

  defp check_label(%{"status" => status, "detail" => detail}) do
    "#{status_label(status)}（#{detail}）"
  end

  defp status_label("passed"), do: "通过"
  defp status_label("failed"), do: "失败"
  defp status_label("skipped"), do: "跳过"
  defp status_label("not_run"), do: "未运行"

  # The deliver receipt is the artifact's own acceptance, so the page says
  # whether *this* version passed it; the browser check is a separate claim with
  # its own truth and is never folded into the delivery line.
  defp deliver_label("succeeded"), do: "通过（这一版已通过交付验收）"
  defp deliver_label("failed"), do: "失败（这一版未被采纳）"
  defp deliver_label("queued"), do: "尚未交付"

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: String.trim(value)
  # A structured field is not a reference: anything that is not a string is
  # treated as empty rather than handed on as an issue id.
  defp blank_to_nil(_value), do: nil

  defp split_lines(nil), do: []
  defp split_lines(text), do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp line_suffix(%{"line" => nil}), do: ""
  defp line_suffix(%{"line" => line, "end_line" => end_line}) when is_integer(end_line), do: ":#{line}-#{end_line}"
  defp line_suffix(%{"line" => line}), do: ":#{line}"

  # Only ever called on a 40-character revision or digest, where the first
  # twelve characters are enough to recognise it and short enough to sit in a
  # sentence.
  defp short(value), do: String.slice(value, 0, 12) <> "…"

  defp embed_url(viewer), do: pinned(viewer, viewer["embed_url"])
  defp standalone_url(viewer), do: pinned(viewer, viewer["standalone_url"])

  # A frame is always pinned to the revision the page labelled, so a later
  # publication can never quietly change what an open page is showing.
  defp pinned(viewer, url), do: url <> "&rev=#{viewer["revision"]}"

  defp kinds, do: @kinds

  defp new_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
