defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard, workbench and API.

  `/` and `/api/v1/*` keep their original meaning; the workbench is additive at
  `/workbench`, so the runtime view never has to move for it.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/workbench.css", StaticAssetController, :workbench_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)

    get("/workbench", WorkbenchEntryController, :index)
    live("/workbench/issues", Workbench.IssuesLive, :index)
    live("/workbench/issues/:identifier", Workbench.IssueDetailLive, :show)
    live("/workbench/devices", Workbench.DevicesLive, :index)
    live("/workbench/reviews", Workbench.ReviewsLive, :index)
    live("/workbench/reviews/:decision_id", Workbench.ReviewsLive, :show)
    live("/workbench/architecture", Workbench.ArchitectureLive, :index)
    live("/workbench/architecture/:artifact_id", Workbench.ArchitectureLive, :show)
  end

  # Delivered diagram bytes are served outside the browser pipeline: the frame
  # that loads them must not carry the application's session or shell.
  scope "/", SymphonyElixirWeb do
    get("/workbench/architecture/:artifact_id/artifact/:kind", WorkbenchArchitectureController, :artifact)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
