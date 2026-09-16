defmodule SymphonyElixirWeb.WorkbenchComponents do
  @moduledoc """
  Soft Glass shell and pieces shared by every workbench page.

  The shell is deliberately the only place that knows about navigation: a page
  renders its own body and gets the two-row header, the demonstration notice and
  the account entry for free, so no page can quietly drop them.
  """

  use Phoenix.Component

  alias SymphonyElixir.Experience.IssueView

  @nav [
    {"/workbench/issues", "Issues"},
    {"/workbench/architecture", "项目架构"},
    {"/workbench/devices", "设备"},
    {"/workbench/reviews", "审阅记录"}
  ]

  @doc """
  Two-row workbench shell: identity and account entry on top, product
  destinations below. The account entry stays reachable even when the
  demonstration fixtures show no avatar in their generated previews.
  """
  attr(:active, :string, required: true)
  attr(:project_id, :string, default: nil)
  attr(:notice, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:actor, :string, default: "本机操作者")
  slot(:inner_block, required: true)
  slot(:toolbar)

  @spec shell(map()) :: Phoenix.LiveView.Rendered.t()
  def shell(assigns) do
    ~H"""
    <div class="wb-shell">
      <nav class="wb-nav" aria-label="工作台导航">
        <div class="wb-nav-row">
          <span class="wb-brand">Symphony</span>
          <span class="wb-brand-sep" aria-hidden="true">/</span>
          <span class="wb-workspace">{@project_id || "未配置项目"}</span>

          <div class="wb-nav-right">
            <a class="wb-nav-link" href="/">查看运行状态</a>
            <a class="wb-nav-link" href="/workbench/issues">设置</a>
            <span class="wb-nav-meta">{@actor}</span>
            <span class="wb-avatar" aria-hidden="true">机</span>
          </div>
        </div>

        <div class="wb-nav-row">
          <div class="wb-nav-links">
            <a
              :for={{href, label} <- nav_links()}
              class="wb-nav-link"
              href={href}
              aria-current={if href == @active, do: "page", else: nil}
            >
              {label}
            </a>
          </div>
        </div>
      </nav>

      <main class="wb-main">
        <p :if={@notice} class="wb-notice" role="status">{@notice}</p>
        <p :if={@error} class="wb-banner wb-banner-error" role="alert">{@error}</p>
        {render_slot(@toolbar)}
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc false
  @spec nav_links() :: [{String.t(), String.t()}]
  def nav_links, do: @nav

  @doc "One board column with its own header, count and bottom add action."
  attr(:column, :string, required: true)
  attr(:issues, :list, required: true)
  attr(:total, :integer, default: nil)

  @spec column(map()) :: Phoenix.LiveView.Rendered.t()
  def column(assigns) do
    ~H"""
    <section class="wb-column" aria-label={@column}>
      <header class="wb-column-head">
        <span class={[state_class(@column), "wb-dot", if(terminal_column?(@column), do: "wb-dot-filled", else: "")]} aria-hidden="true"></span>
        <span class="wb-column-title">{@column}</span>
        <span class="wb-column-count">{@total || length(@issues)}</span>
      </header>

      <div class="wb-column-body">
        <.issue_card :for={issue <- @issues} issue={issue} />
      </div>
    </section>
    """
  end

  attr(:issue, :map, required: true)

  @spec issue_card(map()) :: Phoenix.LiveView.Rendered.t()
  def issue_card(assigns) do
    ~H"""
    <a class="wb-issue-card" href={"/workbench/issues/" <> @issue["identifier"]}>
      <p class="wb-issue-key">{@issue["identifier"]}</p>
      <p class="wb-issue-title">{@issue["title"]}</p>
      <p :if={@issue["labels"] != []} class="wb-issue-labels">
        <span :for={label <- @issue["labels"]} class="wb-pill">{label}</span>
      </p>
      <p class="wb-issue-foot">
        <span>{@issue["assignee"] || "未指派"}</span>
        <span>{relative_time(@issue["updated_at"])}</span>
      </p>
    </a>
    """
  end

  attr(:column, :string, required: true)

  @spec state_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def state_badge(assigns) do
    ~H"""
    <span class="wb-pill">
      <span class={[state_class(@column), "wb-dot", if(terminal_column?(@column), do: "wb-dot-filled", else: "")]} aria-hidden="true"></span>
      {@column}
    </span>
    """
  end

  @doc "Render an ISO timestamp as a stable relative label, or a dash when absent."
  @spec relative_time(String.t() | nil) :: String.t()
  def relative_time(nil), do: "—"

  def relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> relative_to(at, DateTime.utc_now())
      _error -> "—"
    end
  end

  def relative_time(_value), do: "—"

  defp relative_to(at, now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 0 -> "刚刚"
      seconds < 60 -> "刚刚"
      seconds < 3_600 -> "#{div(seconds, 60)} 分钟前"
      seconds < 86_400 -> "#{div(seconds, 3_600)} 小时前"
      true -> "#{div(seconds, 86_400)} 天前"
    end
  end

  defp terminal_column?(column), do: column in ["已完成", "Done"]
  defp state_class(column) when column in ["待办", "Todo"], do: "wb-col-todo"
  defp state_class(column) when column in ["进行中", "In Progress"], do: "wb-col-progress"
  defp state_class(column) when column in ["待审阅", "Human Review", "Review"], do: "wb-col-review"
  defp state_class(column) when column in ["已完成", "Done"], do: "wb-col-done"
  defp state_class(_column), do: "wb-col-todo"

  @doc "True only when the provider confirmed the effect."
  @spec applied?(map() | nil) :: boolean()
  def applied?(%{"status" => "applied"}), do: true
  def applied?(_operation), do: false

  @doc """
  Turn an operation receipt into the sentence the operator should read.

  A confirmed failure and an unconfirmed outcome are different situations and
  must not share wording: only the unknown case forbids simply retrying.
  """
  @spec receipt_warning(map() | nil) :: String.t() | nil
  def receipt_warning(nil), do: nil
  def receipt_warning(%{"status" => "applied"}), do: nil
  def receipt_warning(%{"status" => "received"}), do: nil

  def receipt_warning(%{"status" => "outcome_unknown", "id" => id}) do
    "操作 #{id} 的结果尚未确认，请先对账，不要直接重发。"
  end

  def receipt_warning(%{"status" => status, "id" => id, "error_code" => code}) do
    "操作 #{id} 状态为 #{status}（#{code || "未记录原因"}）；未产生副作用，可修正后重试。"
  end

  @doc "The wire capability list for one issue, used to disable unsupported actions."
  @spec capability?(IssueView.t(), String.t()) :: boolean()
  def capability?(%IssueView{capabilities: capabilities}, name) do
    Enum.any?(capabilities, fn capability ->
      Map.get(capability, :name) == name and Map.get(capability, :available, false)
    end)
  end
end
