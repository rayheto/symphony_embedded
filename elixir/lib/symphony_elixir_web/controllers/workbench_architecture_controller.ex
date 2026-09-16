defmodule SymphonyElixirWeb.WorkbenchArchitectureController do
  @moduledoc """
  Serves one delivered architecture file, and nothing else.

  The route deliberately sits outside the browser pipeline: no session, no CSRF
  token, no application shell. A frame that sandboxes the document without
  `allow-same-origin` then has no path back into the workbench, which is what
  lets the diagram be embedded without handing it the application's credentials.
  """

  use Phoenix.Controller, formats: [:html, :json]

  alias SymphonyElixir.Experience.{Architecture, Project}

  @kinds %{"html" => "text/html", "ir" => "application/json", "manifest" => "application/json"}

  @spec artifact(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def artifact(conn, %{"artifact_id" => artifact_id, "kind" => kind} = params) do
    with {:ok, media_type} <- media_type(kind),
         {:ok, project} <- Project.load(),
         {:ok, artifact} <- Architecture.get(project, artifact_id, revision(params)),
         {:ok, bytes, _media} <- Architecture.read_file(project, artifact, kind) do
      conn
      |> put_resp_content_type(media_type)
      |> put_artifact_headers()
      |> send_resp(200, bytes)
    else
      {:error, :workbench_disabled, _details} ->
        send_resp(conn, 404, "workbench disabled")

      {:error, code, details} ->
        send_resp(conn, 404, "#{code}: #{inspect(details)}")
    end
  end

  defp media_type(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, media_type} -> {:ok, media_type}
      :error -> {:error, :unknown_artifact_kind, %{kind: kind}}
    end
  end

  defp revision(%{"rev" => revision}) when is_binary(revision) do
    case Integer.parse(revision) do
      {value, ""} when value > 0 -> value
      _other -> nil
    end
  end

  defp revision(_params), do: nil

  # The artifact is inert: it may run its own viewer script and offer its own
  # exports, but it may not reach back into the application origin.
  defp put_artifact_headers(conn) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", content_security_policy())
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
  end

  defp content_security_policy do
    "default-src 'none'; " <>
      "script-src 'unsafe-inline'; style-src 'unsafe-inline' https://fonts.googleapis.com; " <>
      "font-src https://fonts.gstatic.com; img-src data:; " <>
      "connect-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'"
  end
end
