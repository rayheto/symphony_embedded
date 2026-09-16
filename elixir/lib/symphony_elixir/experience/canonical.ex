defmodule SymphonyElixir.Experience.Canonical do
  @moduledoc """
  Canonical JSON encoding used for every durable engineering record.

  The store checksums records over a byte-stable representation: UTF-8, object
  keys sorted, no insignificant whitespace. Two encodings of the same logical
  value therefore produce the same digest, which is what makes
  `payload_sha256` meaningful across processes and restarts.
  """

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    {:ok, IO.iodata_to_binary(encode_value(term))}
  rescue
    error -> {:error, {:canonical_encode_failed, error}}
  end

  @spec encode!(term()) :: binary()
  def encode!(term) do
    IO.iodata_to_binary(encode_value(term))
  end

  @spec sha256(term()) :: String.t()
  def sha256(term) do
    term
    |> encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    Jason.decode(binary)
  end

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"

  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)

  defp encode_value(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 1.0e15 do
      [Integer.to_string(trunc(value)), ".0"]
    else
      :erlang.float_to_binary(value, [:short])
    end
  end

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value) do
      Jason.encode!(value)
    else
      raise ArgumentError, "canonical JSON requires valid UTF-8; got invalid bytes"
    end
  end

  defp encode_value(value) when is_atom(value) do
    raise ArgumentError, "canonical JSON does not encode atoms: #{inspect(value)}"
  end

  defp encode_value(value) when is_list(value) do
    ["[", value |> Enum.map(&encode_value/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_value(%DateTime{} = value), do: encode_value(DateTime.to_iso8601(value))

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.map(fn {key, nested} -> {encode_key(key), nested} end)
      |> Enum.sort_by(fn {key, _nested} -> key end)

    [
      "{",
      pairs
      |> Enum.map(fn {key, nested} -> [key, ":", encode_value(nested)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp encode_value(value) when is_struct(value) do
    raise ArgumentError, "canonical JSON does not encode structs: #{inspect(value.__struct__)}"
  end

  defp encode_value(value) do
    raise ArgumentError, "canonical JSON cannot encode #{inspect(value)}"
  end

  defp encode_key(key) when is_binary(key), do: Jason.encode!(key)

  defp encode_key(key) when is_atom(key), do: Jason.encode!(Atom.to_string(key))

  defp encode_key(key) when is_integer(key), do: Jason.encode!(Integer.to_string(key))

  defp encode_key(key), do: raise(ArgumentError, "canonical JSON key must be a string: #{inspect(key)}")
end
