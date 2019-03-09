# ExPirate

Yo-ho-ho! `ExPirate` is a layer on top of the `AgentMap` library that provides
TTL and statistics.

See [documentation](https://hexdocs.pm/ex_pirate) for the details.

## Supported attributes

Each stored value is wrapped in a map ("item"). This item may contain the
following keys ("attributes"):

  * `value: term`;

  * `ttl: pos_integer` — the period (in ms) counted from the insertion or the
    last update during which this item can be used. A default TTL value can be
    given as option to `start/1` or `start_link/1` and updated via `set_prop/3`;

  * `expired?: (item -> boolean)` — indicator of item to be expired (used
    instead of TTL).

— this attributes are user customized. Also, `ExPirate` recognizes and
automatically updates the following properties of item:

  * `inserted_at: integer` — is stamped with
    `System.monotonic_time(:millisecond)` the first time item appears;

  * `updated: pos_integer` (times) — is an update count;

  * `updated_at: integer` — is stamped every time when item is changed;

  * `:used(_at)` — is stamped every time when value is requested;

  * `:missed(_at)` — is stamped every time when value is missing.

By default, `ExPirate` stores only `:inserted_at` (and later `:updated_at`)
attribute for items with TTL. To turn on other statistics provide `attrs:
[:updated | :updated_at | :inserted_at | :used | …]` option on
start (see docs).

```elixir
iex> {:ok, ep} = ExPirate.start() # ttl: ∞
...>
iex> ep
...> |> put(:key, 42)
...> |> get(:key)
42
iex> get(ep, :key, raw: true)
%{value: 42}
#
iex> ep
...> |> put(:key, 24, ttl: 5000)
...> |> get(:key, raw: true)
...> |> Map.keys()
[:ttl, :updated_at, :value]
```

## Expired items

To decide which item is expired, either "time to live" attribute (`:ttl`) is
used or a custom indicator (`:expired?`).

TTL is a period of time in milliseconds, counted *from insert* (`:inserted_at`
attribute) or *from the last update* (`:updated_at`). `ExPirate` will never
return or use an expired item in calculations:

```elixir
iex> {:ok, ep} = ExPirate.start()
...>
iex> ep
...> |> put(:key, 42, ttl: 20)
...> |> fetch(:key)
{:ok, 42}
#
iex> sleep(30)
...>
iex> fetch(ep, :key)
{:error, :expired}
#
iex> put(ep, :key, 43)  # no TTL is given
...>                    #
iex> sleep(30)
iex> fetch(ep, :key)
{:ok, 43}
```

Also, can be used a custom indicator — an unary function that takes item as an
argument:

```elixir
iex> {:ok, ep} =
...>   ExPirate.start(ttl: 20, attrs: [:used])
...>
iex> ep
...> |> put(:key, 42, expired?: & &1[:used] > 1)
...> |> fetch(:key)
{:ok, 42}             # used: 1
#
iex> sleep(50)
iex> fetch(ep, :key)
{:ok, 42}             # used: 2, … still there!
#
iex> sleep(50)        # !
iex> fetch(ep, :key)
{:error, :expired}    # used: 2
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ex_pirate` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_pirate, "~> 0.1.0"}
  ]
end
```

