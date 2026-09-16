defmodule SymphonyElixirWeb.Workbench.DevicesLive do
  @moduledoc """
  Devices and their physical evidence.

  A device is only "online" when the host can actually see it, and a capture
  session shows the bytes that arrived — never a value the page invented.
  Connection is not verification, so the page keeps saying so.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :workbench}

  alias SymphonyElixir.Devices.Manager
  alias SymphonyElixir.Experience.Project
  alias SymphonyElixirWeb.WorkbenchComponents

  @tabs ~w(overview serial)
  @row_limit 500

  @impl true
  def mount(_params, _session, socket) do
    case Project.load() do
      {:ok, project} ->
        {:ok,
         assign(socket,
           project: project,
           unavailable: nil,
           devices: [],
           devices_available?: true,
           selected: nil,
           tab: "overview",
           rows: [],
           paused: false,
           paused_at_count: 0,
           load_error: nil,
           notice: nil,
           pending: new_key()
         )}

      {:error, code, details} ->
        {:ok, assign(socket, unavailable: {code, details}, tab: "overview")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns[:project] do
      {:noreply,
       socket
       |> assign(:selected_key, params["device"])
       |> assign(:tab, normalize_tab(params["tab"]))
       |> load()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, probe_all(socket)}

  def handle_event("select", %{"device" => device_key}, socket) do
    {:noreply, push_patch(socket, to: "/workbench/devices?device=#{device_key}&tab=#{socket.assigns.tab}")}
  end

  def handle_event("start-capture", _params, socket) do
    device = socket.assigns.selected

    case Manager.open_capture(Manager, device["id"],
           project_id: socket.assigns.project.project_id,
           store: socket.assigns.project.store,
           owner: self()
         ) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(notice: "采集已开始：#{session["session_id"]}", load_error: nil)
         |> load()}

      {:error, code, details} ->
        {:noreply, assign(socket, load_error: "无法开始采集：#{code} #{inspect(details)}")}
    end
  end

  def handle_event("stop-capture", _params, socket) do
    device = socket.assigns.selected

    case Manager.close_capture(Manager, device["id"]) do
      {:ok, _closed} ->
        {:noreply, socket |> assign(notice: "已请求停止采集；物理动作的停止需另行确认。", load_error: nil) |> load()}

      {:error, code, details} ->
        {:noreply, assign(socket, load_error: "无法停止采集：#{code} #{inspect(details)}")}
    end
  end

  @doc """
  Freeze the viewport without touching the capture.

  Pausing only stops the *page* from following new rows; the device keeps being
  read and its chunks keep being written.
  """
  def handle_event("toggle-scroll", _params, socket) do
    paused = not socket.assigns.paused

    {:noreply,
     assign(socket,
       paused: paused,
       paused_at_count: if(paused, do: length(socket.assigns.rows), else: 0)
     )}
  end

  @impl true
  def handle_info({:serial, _message}, socket), do: {:noreply, refresh_rows(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <WorkbenchComponents.shell
        :if={!@unavailable}
        active="/workbench/devices"
        project_id={@project.project_id}
        notice={@notice}
        error={@load_error}
      >
        <:toolbar>
          <div class="wb-page-head">
            <h1 class="wb-title">设备</h1>
            <p class="wb-subtitle">{summary(@devices)}</p>
            <div class="wb-spacer"></div>
            <button class="wb-btn" phx-click="refresh" type="button">刷新</button>
          </div>
        </:toolbar>

        <p :if={@devices == [] and @devices_available?} class="wb-panel wb-banner-empty">
          宿主没有登记任何设备。设备清单来自宿主的 devices.yaml，不在界面里新增。
        </p>

        <p :if={!@devices_available?} class="wb-panel wb-banner-empty">
          设备管理未运行，无法读取宿主设备清单。其它页面不受影响。
        </p>

        <section :if={@devices != []} class="wb-panel">
          <table class="wb-table">
            <caption>选择一台设备查看采集与观测</caption>
            <thead>
              <tr>
                <th scope="col">设备</th>
                <th scope="col">连接</th>
                <th scope="col">构建</th>
                <th scope="col">占用</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={device <- @devices}
                phx-click="select"
                phx-value-device={device["id"]}
                aria-selected={@selected && @selected["id"] == device["id"]}
              >
                <td>
                  <strong>{device["display_name"]}</strong>
                  <span class="wb-muted">{device["hardware_revision"] || "—"}</span>
                </td>
                <td>{device["connection_status"]}</td>
                <td>{device["build_id"] || "未知"}</td>
                <td>{lease_label(device["lease"])}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@selected} class="wb-split wb-split-60-40">
          <article class="wb-panel">
            <div class="wb-page-head">
              <h2 class="wb-section-title">{@selected["display_name"]}</h2>
              <div class="wb-spacer"></div>
              <div class="wb-segmented" role="group" aria-label="设备视图">
                <a
                  :for={tab <- tabs()}
                  href={"/workbench/devices?device=#{@selected["id"]}&tab=#{tab}"}
                  aria-selected={@tab == tab}
                >
                  {tab_label(tab)}
                </a>
              </div>
            </div>

            <div :if={@tab == "overview"} class="wb-field">
              <dl class="wb-dl">
                <dt>适配器</dt>
                <dd>{@selected["adapter"]}</dd>
                <dt>端口</dt>
                <dd class="wb-mono">{@selected["port"]}</dd>
                <dt>硬件版本</dt>
                <dd>{@selected["hardware_revision"] || "未知"}</dd>
                <dt>采集会话</dt>
                <dd class="wb-mono">{@selected["active_session_id"] || "未采集"}</dd>
                <dt>当前占用</dt>
                <dd>{lease_label(@selected["lease"])}</dd>
              </dl>

              <p class="wb-banner wb-banner-warning">
                在线只表示连接可用，不代表验证通过。控制操作独占，日志可共享查看。
              </p>
            </div>

            <div :if={@tab == "serial"} class="wb-field">
              <div class="wb-toolbar">
                <button
                  :if={!@selected["active_session_id"]}
                  class="wb-btn wb-btn-primary"
                  phx-click="start-capture"
                  type="button"
                >
                  开始采集
                </button>
                <button :if={@selected["active_session_id"]} class="wb-btn" phx-click="stop-capture" type="button">
                  停止采集
                </button>
                <button class="wb-btn" phx-click="toggle-scroll" type="button">
                  {if @paused, do: "恢复滚动", else: "暂停滚动"}
                </button>
                <span class="wb-muted">最近 {@rows |> length()} 行</span>
              </div>

              <p :if={@rows == []} class="wb-muted">还没有采集到的原始字节。</p>

              <pre :if={@rows != []} class="wb-log" aria-label="串口原始记录" tabindex="0"><span
                :for={row <- @rows}
                class="wb-log-line"
              ><span class="wb-log-gutter">{row["source_seq"]}</span> {row["display_text"]}</span></pre>

              <p :if={@paused} class="wb-muted">
                已暂停滚动；采集与写盘仍在继续，未读 {unread_count(@rows, @paused_at_count)} 行。
              </p>
              <p :if={@rows != [] and @paused == false} class="wb-muted">
                显示文本是原始字节的派生视图；完整字节以 chunk 形式保存在证据存储中。
              </p>
            </div>
          </article>

          <aside class="wb-panel">
            <h2 class="wb-section-title">能力</h2>
            <ul class="wb-list">
              <li :for={capability <- @selected["capabilities"]}>
                <span class="wb-pill">{capability.name}</span>
                <span class="wb-muted">
                  {if capability.available, do: "可用", else: capability.reason}
                </span>
              </li>
            </ul>

            <h2 class="wb-section-title">验证范围</h2>
            <p class="wb-muted">真机复测未完成；本页只展示宿主实际观测到的内容。</p>
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
    devices = list_devices()

    selected =
      case socket.assigns[:selected_key] do
        nil -> nil
        key -> Enum.find(devices, &(&1["id"] == key))
      end

    socket
    |> assign(devices: devices, devices_available?: Process.whereis(Manager) != nil, selected: selected)
    |> refresh_rows()
  end

  # A device manager that is not running is a degraded read, not a broken page:
  # the rest of the workbench keeps working without it.
  defp list_devices do
    Manager.list(Manager)
  catch
    :exit, _reason -> []
  end

  defp probe_all(socket) do
    devices =
      Enum.map(socket.assigns.devices, fn device ->
        {:ok, probe} = Manager.probe(Manager, device["id"])
        Map.merge(device, %{"connection_status" => probe["connection_status"]})
      end)

    selected =
      case socket.assigns[:selected] do
        nil -> nil
        selected -> Enum.find(devices, &(&1["id"] == selected["id"]))
      end

    assign(socket, devices: devices, selected: selected)
  end

  defp refresh_rows(socket) do
    case socket.assigns[:selected] do
      nil ->
        assign(socket, rows: [])

      %{"active_session_id" => nil} ->
        assign(socket, rows: [])

      selected ->
        rows = session_rows(selected["id"])
        assign(socket, rows: rows)
    end
  end

  # A manager that is not running yields no rows rather than taking the page
  # down; the capture itself is unaffected.
  defp session_rows(device_key) do
    case Process.whereis(Manager) do
      nil -> []
      _pid -> Manager.recent(Manager, device_key, @row_limit)
    end
  end

  defp normalize_tab(tab) when tab in @tabs, do: tab
  defp normalize_tab(_tab), do: "overview"

  @doc "The device detail tabs, in display order."
  @spec tabs() :: [String.t()]
  def tabs, do: @tabs

  defp tab_label("overview"), do: "概览"
  defp tab_label("serial"), do: "串口"

  defp summary([]), do: "宿主没有登记设备。"
  defp summary(devices), do: "#{length(devices)} 台设备"

  defp lease_label(nil), do: "无"
  defp lease_label(%{"owner_run_id" => owner}), do: owner

  # Rows that arrived while the page was frozen; the capture is still reading.
  defp unread_count(rows, paused_at_count) do
    max(length(rows) - paused_at_count, 0)
  end

  defp new_key do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
