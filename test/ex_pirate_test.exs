defmodule ExPirateTest do
  use ExUnit.Case

  import :timer
  import ExPirate

  doctest ExPirate

  test "delete/3 also removes :ttl and :expired?" do
    {:ok, ep} = ExPirate.start()

    ep
    |> put(:a, 42, ttl: 20)
    |> put(:b, 42, expired?: fn _ -> false end)
    |> delete(:a)
    |> delete(:b)

    a = get(ep, :a, raw: true)
    b = get(ep, :b, raw: true)

    refute Map.has_key?(a, :ttl)
    refute Map.has_key?(b, :expired?)
  end

  test "delete/3 also removes :inserted_at when it's not needed" do
    {:ok, ep} = ExPirate.start()

    ep
    |> put(:key, 42, ttl: 20)
    |> delete(:key)

    item = get(ep, :key, raw: true)

    refute Map.has_key?(item, :inserted_at)
    refute Map.has_key?(item, :expired?)
  end

  test "put/4 will not stamp :updated and :updated_at if value was not changed" do
    import Map, only: [has_key?: 2]

    {:ok, ep} = ExPirate.start(attrs: [:updated, :updated_at])

    a = ep
        |> put(:a, 42, ttl: 20)
        |> put(:a, 42)
        |> get(:a, raw: true)

    assert has_key?(a, :updated) || has_key?(a, :updated_at)
    refute has_key?(a, :inserted_at)

    b = ep
        |> put(:b, 42, ttl: 20)
        |> put(:b, 24)
        |> get(:b, raw: true)

    assert has_key?(b, :updated) && has_key?(b, :updated_at)
    refute has_key?(b, :inserted_at)
  end
end
