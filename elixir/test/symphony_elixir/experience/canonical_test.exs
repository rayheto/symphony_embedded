defmodule SymphonyElixir.Experience.CanonicalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Experience.Canonical

  test "encodes scalars in a byte-stable form" do
    assert Canonical.encode!(nil) == "null"
    assert Canonical.encode!(true) == "true"
    assert Canonical.encode!(false) == "false"
    assert Canonical.encode!(12) == "12"
    assert Canonical.encode!(1.0) == "1.0"
    assert Canonical.encode!(1.5) == "1.5"
    assert Canonical.encode!("hi") == ~s("hi")
    assert Canonical.encode!("汉") == ~s("汉")
  end

  test "sorts object keys so equal maps encode identically" do
    left = %{"b" => 1, "a" => 2}
    right = %{"a" => 2, "b" => 1}

    assert Canonical.encode!(left) == ~s({"a":2,"b":1})
    assert Canonical.encode!(left) == Canonical.encode!(right)
    assert Canonical.sha256(left) == Canonical.sha256(right)
  end

  test "sorts nested objects and preserves list order" do
    value = %{"outer" => %{"z" => [3, 1], "y" => %{"n" => nil}}}

    assert Canonical.encode!(value) == ~s({"outer":{"y":{"n":null},"z":[3,1]}})
  end

  test "encodes date times as ISO-8601 strings" do
    dt = ~U[2026-09-15 10:00:00Z]

    assert Canonical.encode!(dt) == ~s("2026-09-15T10:00:00Z")
  end

  test "refuses tuples as values and as object keys" do
    assert {:error, {:canonical_encode_failed, %ArgumentError{}}} = Canonical.encode(%{"k" => {1, 2}})
    assert {:error, {:canonical_encode_failed, %ArgumentError{}}} = Canonical.encode(%{{1, 2} => "v"})
  end

  test "refuses values that have no stable wire form" do
    assert {:error, {:canonical_encode_failed, _reason}} = Canonical.encode(%{key: :atom})
    assert {:error, {:canonical_encode_failed, _reason}} = Canonical.encode(%{1 => :atom})
    assert {:error, {:canonical_encode_failed, _reason}} = Canonical.encode(%{key: ~D[2026-09-15]})
    assert {:error, {:canonical_encode_failed, _reason}} = Canonical.encode(%{key: <<0xFF, 0xFE>>})
  end

  test "round-trips through decode" do
    value = %{"a" => [1, %{"b" => "c"}], "d" => nil}

    assert {:ok, decoded} = Canonical.decode(Canonical.encode!(value))
    assert decoded == value
  end

  test "decodes invalid JSON as an error" do
    assert {:error, _reason} = Canonical.decode("{")
  end
end
