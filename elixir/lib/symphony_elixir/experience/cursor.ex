defmodule SymphonyElixir.Experience.Cursor do
  @moduledoc """
  Opaque list cursors.

  A cursor is bound to the project, the filter set and the snapshot it was taken
  from. Reusing it against a different filter or an older snapshot is reported
  as `:cursor_expired` instead of silently returning a page from another query,
  which would look like missing or duplicated rows.
  """

  alias SymphonyElixir.Experience.Canonical

  @spec encode(map()) :: String.t()
  def encode(fields) when is_map(fields) do
    fields
    |> Canonical.encode!()
    |> Base.url_encode64(padding: false)
  end

  @spec decode(term()) :: {:ok, map()} | {:error, :invalid_cursor, map()}
  def decode(nil), do: {:ok, %{}}

  def decode(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, fields} when is_map(fields) <- Jason.decode(decoded) do
      {:ok, fields}
    else
      _error -> {:error, :invalid_cursor, %{cursor: cursor}}
    end
  end

  def decode(cursor), do: {:error, :invalid_cursor, %{cursor: cursor}}

  @doc """
  Check a decoded cursor against the query that is asking for the next page.
  """
  @spec validate(map(), map()) :: :ok | {:error, :cursor_expired, map()}
  # An absent cursor decodes to an empty map and always means "first page".
  def validate(fields, _expected) when map_size(fields) == 0, do: :ok

  def validate(fields, expected) do
    mismatch =
      expected
      |> Enum.filter(fn {key, value} -> Map.get(fields, key) != value end)
      |> Enum.map(&elem(&1, 0))

    case mismatch do
      [] -> :ok
      keys -> {:error, :cursor_expired, %{changed: keys}}
    end
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(filters) when is_map(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
    |> Canonical.sha256()
  end
end
