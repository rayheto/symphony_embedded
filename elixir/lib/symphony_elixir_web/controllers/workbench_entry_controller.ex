defmodule SymphonyElixirWeb.WorkbenchEntryController do
  @moduledoc """
  `/workbench` is a stable product entry point, not a page of its own.

  It forwards to the Issues board, so a link to "the workbench" keeps working
  even if the default destination changes later.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    redirect(conn, to: "/workbench/issues")
  end
end
