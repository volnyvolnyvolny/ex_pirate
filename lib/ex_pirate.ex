defmodule ExPirate do
  require Logger

  import ExPirate.Utils

  use AgentMap

  @moduledoc """
  Yo-ho-ho! `ExPirate` is a layer on top of the `AgentMap` library that provides
  TTL and statistics.

  ## Supported attributes

  Each stored value is wrapped in a map ("item"). This item may contain the
  following keys ("attributes"):

    * `value: term`;

    * `ttl: pos_integer` — the period (in ms) counted from the insertion or the
      last update during which this item can be used. A default TTL value can be
      given as option to `start/1` or `start_link/1` and updated via
      `set_prop/3`;

    * `expired?: (item -> boolean)` — indicator of item to be
      [expired](#module-expired-items) (used instead of TTL).

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
  [start](#start_link/1-options).

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

  ## Expired items

  To decide which item is expired, either "time to live" attribute (`:ttl`) is
  used or a custom indicator (`:expired?`).

  TTL is a period of time in milliseconds, counted *from insert* (`:inserted_at`
  attribute) or *from the last update* (`:updated_at`). `ExPirate` will never
  return or use an expired item in calculations:

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

  Also, can be used a custom indicator — an unary function that takes item as an
  argument:

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
  """

  @type key :: any
  @type value :: any
  @type t :: AgentMap.t()
  @type ep :: ExPirate.t()
  @type reason :: term

  @typedoc "Custom attribute."
  @type custom :: atom
  @type default :: term

  @type attr ::
          :inserted_at
          | :used
          | :used_at
          | :updated
          | :updated_at
          | :missed
          | :missed_at
          | :expired?
          | :ttl
          | custom

  @doc false
  defguard is_timeout(t)
           when (is_integer(t) and t > 0) or t == :infinity

  @typedoc """
  Wrapper for a value.
  """
  @type item :: %{
          optional(:value) => term,
          optional(:used_at | :missed_at | :updated_at | :inserted_at) => integer,
          optional(:used | :updated | :missed) => non_neg_integer,
          optional(:expired?) => (item -> boolean),
          optional(:ttl) => pos_integer,
          optional(custom) => term
        }

  @attrs_at [:inserted_at, :updated_at, :used_at, :missed_at]

  #
  ## HELPERS
  #

  @compile {:inline, now: 0}

  defp now(), do: System.monotonic_time()

  #
  ## GC, STAMP, EXPIRED?
  #

  defp gc(item, ep) do
    attrs = item[:attrs] || get_prop(ep, :attrs)
    keys = Map.keys(item)

    # dealing with :ttl and :expired?:
    item =
      if Map.has_key?(item, :value) do
        if Map.has_key?(item, :expired?) && Map.has_key?(item, :ttl) do
          #
          Logger.warn("""
          Item has both :ttl and :expired? attributes. Attribute :ttl is
          deleted.

          Item: #{inspect(item)}
          """)

          Map.delete(item, :ttl)
        end || item
      else
        item
        |> Map.delete(:ttl)
        |> Map.delete(:expired?)
        |> Map.delete(:inserted_at)
      end

    # dealing with :inserted_at and :updated_at attributes:
    suspicious? = &(Map.has_key?(item, &1) && &1 not in attrs)

    item =
      if suspicious?.(:inserted_at) || suspicious?.(:updated_at) do
        # :inserted_at or :updated_at is in the list of keys,
        # but not in the `attrs`

        if :ttl in keys || (:expired? not in keys && get_prop(ep, :ttl)) do
          if Map.has_key?(item, :updated_at) do
            Map.delete(item, :inserted_at)
          end
        else
          collect = fn item, attr ->
            if suspicious?.(attr) do
              Map.delete(item, attr)
            end || item
          end

          item
          |> collect.(:inserted_at)
          |> collect.(:updated_at)
        end
      end || item

    #
    attrs = MapSet.new([:inserted_at, :updated_at | attrs])
    known = MapSet.new([:updated, :used, :missed] ++ @attrs_at)

    #
    keys = MapSet.new(keys)
    known_keys = MapSet.intersection(known, keys)

    Map.drop(item, MapSet.difference(known_keys, attrs))
  end

  #
  #

  defp stamp(item, prop) when prop in @attrs_at do
    Map.put(item, prop, now())
  end

  defp stamp(item, prop) do
    Map.update(item, prop, 1, &(&1 + 1))
  end

  #

  defp stamp(ep, key, props) do
    stamp = fn item, ep ->
      item =
        props
        |> Enum.reduce(item, &stamp(&2, &1))
        |> gc(ep)

      {:_done, item}
    end

    AgentMap.get_and_update(
      ep,
      key,
      fn
        nil ->
          stamp.(%{}, ep)

        item ->
          stamp.(item, ep)
      end,
      cast: true
    )

    ep
  end

  #
  #

  defp expired?(_ep, %{ttl: nil, expired?: nil}), do: false

  #

  defp expired?(ep, %{ttl: nil} = item) do
    expired?(ep, Map.delete(item, :ttl))
  end

  defp expired?(ep, %{expired?: nil} = item) do
    expired?(ep, Map.delete(item, :expired?))
  end

  #

  defp expired?(_ep, %{expired?: e} = item) do
    item
    |> Map.put_new(:updated, 0)
    |> Map.put_new(:used, 0)
    |> Map.put_new(:missed, 0)
    |> e.()
  end

  defp expired?(ep, %{ttl: t} = item) do
    m =
      item[:inserted_at] || item[:updated_at] ||
        get_prop(ep, :inserted_at)

    if m do
      p = System.convert_time_unit(t, :millisecond, :native)
      m + p <= now()
    else
      raise """
      Item #{inspect(item)} has :ttl value being set,
      but no :inserted_at or :updated_at attributes
      are to count from.
      """
    end
  end

  defp expired?(ep, item) do
    item =
      item
      |> Map.put(:expired?, get_prop(ep, :expired?))
      |> Map.put(:ttl, get_prop(ep, :ttl))

    expired?(ep, item)
  end

  #
  ## START, START_LINK, STOP
  #

  @doc """
  Starts instance that is linked to the current process.

  ## Options

    * `name: term` — is used for registration as described in the module
      documentation;

    * `:debug` — is used to invoke the corresponding function in [`:sys`
      module](http://www.erlang.org/doc/man/sys.html);

    * `:spawn_opt` — is passed as options to the underlying process as in
      `Process.spawn/4`;

    * `:timeout`, `5000` — `ExPirate` is allowed to spend at most the given
      number of milliseconds on the whole process of initialization or it will
      be terminated;

    * `attrs: [:updated, :updated_at, :used, :used_at, :missed, :missed_at]`,
      `[]` — attributes that are stored and automatically updated;

    * `expired?: (item -> boolean)` — custom indicator of [expired
      item](#module-expired-items);

    * `ttl: pos_integer` — default period (in ms) counted from `:updated_at`
      during which item is considered fresh.

  ## Return values

  If an instance is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a server with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    start([{:link, true} | opts])
  end

  @doc """
  Start as an unlinked process.

  See `start_link/1` for details.
  """
  @spec start(keyword) :: GenServer.on_start()
  def start(opts \\ []) do
    case AgentMap.start([], opts) do
      {:ok, pid} = ok ->
        #
        for p <- [:ttl, :expired?, :attrs], opts[p] do
          set_prop(pid, p, opts[p])
        end

        ok

      err ->
        err
    end
  end

  @doc """
  Synchronously stops the `ExPirate` instance with the given `reason`.

  Returns `:ok` if terminated with the given reason. If it terminates with
  another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ### Examples

      iex> {:ok, pid} = ExPirate.start_link()
      iex> ExPirate.stop(pid)
      :ok
  """
  @spec stop(ep, reason :: term, timeout) :: :ok
  def stop(ep, reason \\ :normal, timeout \\ :infinity) do
    AgentMap.stop(ep, reason, timeout)
  end

  #
  ## KEYS, TO_MAP
  #

  # @doc """
  # Returns all keys that have values.

  # ## Options

  #   * `raw: true` — to act as `AgentMap.keys/1`.

  # ## Examples

  #     iex> {:ok, ep} = ExPirate.start(attrs: [:updated])
  #     iex> ep
  #     ...> |> put(:a, 1)
  #     ...> |> put(:b, nil)
  #     ...> |> put(:c, 3)
  #     ...> |> delete(:c)
  #     ...> |> keys()
  #     [:a, :b]
  #     iex> keys(ep, raw: true)     # = AgentMap.keys(ep)
  #     [:a, :b, :c]
  #     iex> get(ep, :c, raw: true)
  #     %{updated: 1}
  # """
  # @spec keys(ep, keyword) :: [key]
  # def keys(ep, opts \\ [raw: false]) do
  #   if opts[:raw] do
  #     AgentMap.keys(ep)
  #   else
  #     get_prop(ep, :keys)
  #   end
  # end

  # @doc """
  # Returns a current `Map` representation. Only keys with values that are not
  # expired are included.

  # ## Options

  #   * `raw: true` — to act as `AgentMap.to_map/1`.

  # ## Examples

  #     iex> {:ok, ep} = ExPirate.start(attrs: [:updated])
  #     iex> ep
  #     ...> |> put(:a, 1)           # updated: +1
  #     ...> |> put(:b, nil)         # updated: +1
  #     ...> |> put(:c, 3)           # updated: +1
  #     ...> |> delete(:c)
  #     ...> |> keys()
  #     [:a, :b]
  #     iex> keys(ep, raw: true)     # = AgentMap.keys(ep)
  #     [:a, :b, :c]
  #     iex> get(ep, :c, raw: true)
  #     %{updated: 1}
  # """
  # @spec to_map(ep, keyword) :: %{required(key) => value | item}
  # def to_map(ep, opts \\ [raw: false]) do
  #   if opts[:raw] do
  #     AgentMap.to_map(ep)
  #   else
  #     m = AgentMap.take(ep, keys(ep))
  #     c = criteria(ep) # that item is expired

  #     for {k, %{value: v} = i} <- m, not expired?(i, c), into: %{} do
  #       {k, v}
  #     end
  #   end
  # end

  #
  ## DELETE, DROP
  #

  @doc """
  Deletes *value* for `key` while keeps statistics.

  Returns without waiting for the actual deletion to occur.

  Default priority for this call is `:max`.

  ## Options

    * `cast: false` — to return only after the actual delete;

    * `raw: true` — to delete item via `AgentMap.delete/3`;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} =
      ...>   ExPirate.start(attrs: [:missed])
      ...>
      iex> ep
      ...> |> put(:key, 42)
      ...> |> delete(:key)
      ...> |> fetch(:key)
      {:error, :missing}
      #
      iex> get(ep, :key, raw: true)  # statistics
      %{missed: 1}
      #
      iex> ep
      ...> |> delete(:key, raw: true, cast: false)
      ...> |> get(:key, raw: true)
      %{}
  """
  @spec delete(ep, key, keyword | timeout) :: ep
  def delete(ep, key, opts \\ [cast: true, !: :max, raw: false])

  def delete(ep, key, t) when is_timeout(t) do
    delete(ep, key, timeout: t)
  end

  def delete(ep, key, opts) do
    opts =
      opts
      |> Keyword.put_new(:!, :max)
      |> Keyword.put_new(:cast, true)
      |> Keyword.put_new(:raw, false)
      |> Keyword.put(:tiny, true)

    if opts[:raw] do
      AgentMap.delete(ep, key, opts)
    else
      AgentMap.get_and_update(
        ep,
        key,
        fn
          nil ->
            :id

          item ->
            item =
              if Map.has_key?(item, :value) do
                item
                |> Map.delete(:value)
                |> stamp(:updated)
                |> stamp(:updated_at)
                |> gc(ep)
              else
                gc(item, ep)
              end

            if item == %{} do
              :pop
            else
              {:_ok, item}
            end
        end,
        opts
      )

      ep
    end
  end

  # @doc """
  # Drops given `keys` while keeps statistics.

  # Returns without waiting for the actual drop.

  # This call has a fixed priority `{:avg, +1}`.

  # ## Options

  #   * `cast: false` — to return after the actual drop;

  #   * `raw: true` — to delete items via `AgentMap.drop/3`;

  #   * `:timeout`, `5000`.

  # ## Examples

  #     iex> {:ok, ep} =
  #     ...>   ExPirate.start()
  #     ...>
  #     iex> ep
  #     ...> |> put(:a, 1, ttl: 20)
  #     ...> |> put(:b, 2)
  #     ...> |> put(:c, 3, ttl: 20)
  #     ...> |> put(:d, 4, ttl: 20)
  #     ...> |> drop([:b, :d, :e], cast: false)
  #     ...> |> keys()
  #     [:a, :c]
  #     #
  #     iex> keys(ep, raw: true)
  #     [:a, :c, :d]
  #     iex> ep
  #     ...> |> drop(:all, raw: true)
  #     ...> |> keys(raw: true)
  #     []
  # """
  # @spec drop(ep, Enumerable.t() | :all, keyword) :: ep
  # def drop(ep, keys, opts \\ [cast: true, raw: false]) do
  #   opts =
  #     opts
  #     |> Keyword.put_new(:cast, true)
  #     |> Keyword.put_new(:raw, false)

  #   if opts[:raw] do
  #     AgentMap.drop(ep, keys, opts)
  #   else
  #     # AgentMap.Multi.get_and_update(
  #     #   ep,
  #     #   key,
  #     #   fn it ->
  #     #     item = Map.delete(it, :value)

  #     #     if item == %{} do
  #     #       :pop
  #     #     else
  #     #       {:_ok, item}
  #     #     end
  #     #   end,
  #     #   opts
  #     # )

  #     # ep

  #     throw :TODO!
  #   end
  # end

  #
  ## FETCH, FETCH!
  #

  @doc """
  Fetches the value for a specific `key`.

  Returns:

    * `{:ok, value}`;

    * `{:error, :missing}` if item with such `key` is missing or `:value`
      attribute is not present;

    * `{:error, :expired}` if value is present, but is expired. You can still
      retrive an expired value via `get(ep, key, raw: true).value`.

  ## Options

    * `raw: true` — to return value with statistics, wrapped in an item map;

    * `!: priority`, `:now` — to return only when calls with priorities higher
      than given are finished for this `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} =
      ...>   ExPirate.start(attrs: [:missed, :used, :updated])
      ...>
      iex> fetch(ep, :a)
      {:error, :missing}
      #
      iex> ep
      ...> |> put(:a, 42, ttl: 20, cast: false)
      ...> |> fetch(:a)
      {:ok, 42}
      #
      iex> sleep(20)
      iex> fetch(ep, :a)
      {:error, :expired}
      #
      iex> fetch(ep, :a, raw: true)
      {:error, :expired}
      #
      iex> ep
      ...> |> get(:a, raw: true)
      ...> |> Map.delete(:inserted_at)
      %{used: 1, missed: 3, ttl: 20}
  """
  @spec fetch(ep, key, keyword | timeout) :: {:ok, value | item} | {:error, :missing | :expired}
  def fetch(ep, key, opts \\ [!: :now])

  def fetch(ep, key, t) when is_timeout(t) do
    fetch(ep, key, timeout: t)
  end

  def fetch(ep, key, opts) do
    case AgentMap.fetch(ep, key, opts) do
      {:ok, %{value: v} = item} ->
        if expired?(ep, item) do
          stamp(ep, key, [:missed, :missed_at])

          {:error, :expired}
        else
          stamp(ep, key, [:used, :used_at])

          ret = if opts[:raw], do: item, else: v

          {:ok, ret}
        end

      _ ->
        stamp(ep, key, [:missed, :missed_at])

        {:error, :missing}
    end
  end

  #

  @doc """
  Fetches the value for a specific `key`, erroring out if value is missing *or
  expired*.

  Returns current value or raises a `KeyError`.

  See `fetch/3`.

  ## Options

    * `!: priority`, `:now` — to return only when calls with higher
      [priorities](#module-priority) are finished to execute for this `key`;

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} =
      ...>   ExPirate.start()
      iex> ep
      ...> |> put(:a, 1)
      ...> |> fetch!(:a)
      1
      iex> fetch!(ep, :b)
      ** (KeyError) key :b not found

      iex> {:ok, ep} =
      ...>   ExPirate.start(ttl: 20)
      iex> ep
      ...> |> put(:a, 42)
      ...> |> fetch!(:a)
      42
      #
      iex> sleep(30) # !
      iex> fetch!(ep, :a)
      ** (ValueError) value for the key :a is expired

      iex> {:ok, ep} =
      ...>   ExPirate.start(attrs: [:inserted_at])
      iex> ep
      ...> |> put(:a, 1)
      ...> |> delete(:a)
      ...> |> fetch!(:a)
      ** (KeyError) key :a not found
  """
  @spec fetch!(ep, key, keyword | timeout) :: value | item | no_return
  def fetch!(ep, key, opts \\ [!: :now])

  def fetch!(ep, k, opts) do
    case AgentMap.fetch(ep, k, opts) do
      {:ok, %{value: v} = item} ->
        if expired?(ep, item) do
          stamp(ep, k, [:missed, :missed_at])

          raise ValueError, key: k, reason: :expired
        else
          stamp(ep, k, [:used, :used_at])

          if opts[:raw], do: item, else: v
        end

      {:ok, %{}} ->
        stamp(ep, k, [:missed, :missed_at])

        raise ValueError, key: k, reason: :missing

      :error ->
        raise KeyError, key: k
    end

    # case fetch(ep, k, opts) do
    #   {:ok, ret} ->
    #     ret

    #   {:error, reason} ->
    #     raise ValueError, key: k, reason: reason
    # end
  end

  #
  ## GET
  #

  @doc """
  Gets a value via the given `fun`.

  A callback `fun` is sent to an instance that invokes it, passing as an
  argument the value associated with `key`. The result of an invocation is
  returned from this function. This call does not change value, and so, workers
  execute a series of `get`-calls as a parallel `Task`s.

  ## Options

    * `:default`, `nil` — value for `key` if it's missing or expired;

    * `!: priority`, `:avg`;

    * `!: :now` — to execute call in a separate `Task` spawned from server,
      passing current value (see `AgentMap.get/4`);

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} = ExPirate.start()
      iex> get(ep, :a, & &1)
      nil
      iex> ep
      ...> |> put(:a, 42)
      ...> |> get(:a, & &1 + 1)
      43
      iex> get(ep, :b, & &1 + 1, default: 0)
      1
  """
  @spec get(ep, key, (value | default -> get), keyword | timeout) :: get
        when get: var
  @spec get(ep, key, (item -> get), keyword) :: get
        when get: var
  def get(ep, key, fun, opts)

  def get(ep, key, fun, t) when is_timeout(t) do
    get(ep, key, fun, timeout: t)
  end

  def get(ep, key, fun, opts) do
    #
    AgentMap.get(
      ep,
      key,
      fn item ->
        arg =
          if Map.has_key?(item, :value) && not expired?(ep, item) do
            #
            # OK
            #
            stamp(ep, key, [:used, :used_at])

            if opts[:raw] do
              item
            end || item[:value]
          else
            #
            # ERROR
            #
            stamp(ep, key, [:missed, :missed_at])

            if opts[:raw] do
              if Keyword.has_key?(opts, :default) do
                Map.put(item, :value, opts[:default])
              else
                Map.delete(item, :value)
              end
            end || opts[:default]
          end

        apply(fun, [arg])
      end,
      Keyword.put(opts, :default, %{})
    )
  end

  @doc """
  Returns the value for a specific `key`.

  This call has the `:min` priority. As so, the value is retrived only after all
  other calls for `key` are completed.

  See `get/4`.

  ## Options

    * `:default`, `nil` — value to return if `key` is missing or expired;

    * `raw: true` — to return item instead of just value;

    * `!: priority`, `:min`;

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} =
      ...>   ExPirate.start(attrs: [:used])
      ...>
      iex> get(ep, :key)
      nil                                                # used: 0
      #
      iex> ep
      ...> |> put(:key, 42, expired?: & &1[:used] > 0)
      ...> |> get(:key)
      42                                                 # used: 1
      #
      iex> sleep(30)                                     # !
      iex> get(ep, :key)
      nil                                                # used: 1
      iex> get(ep, :key, default: 0)
      0                                                  # used: 1
      iex> get(ep, :key, raw: true, default: 0).value
      0                                                  # used: 1
      #
      #
      iex> ep
      ...> |> get(:key, raw: true)
      ...> |> Map.take([:value, :used])
      %{used: 1}                                         # no value is returned
      #                                                    as it's expired
      iex> ep
      ...> |> AgentMap.get(:key)
      ...> |> Map.take([:value, :used])
      %{value: 42, used: 1}                              # but it's still there
  """
  @spec get(ep, key, keyword) :: value | item | default
  def get(ep, key, opts \\ [!: :min, raw: false])

  def get(ep, key, opts) when is_list(opts) do
    get(ep, key, & &1, opts)
  end

  def get(ep, key, fun) do
    get(ep, key, fun, [])
  end

  #
  ## UPDATE, UPDATE!
  #

  # @doc """
  # Updates `key` with the given `fun`.

  # See `get_and_update/4`.

  # ## Options

  #   * `:initial`, `nil` — value for `key` if it's missing *or expired*;

  #   * `tiny: true` — to execute `fun` in the servers loop, if worker was not
  #     spawned for `key`;

  #   * `!: priority`, `:avg`;

  #   * `:timeout`, `5000`.

  # ## Examples

  #     iex> {:ok, ep} =
  #     ...>   ExPirate.start(ttl: 20)
  #     iex> ep
  #     ...> |> put(:Alice, 24)
  #     ...> |> update(:Alice, & &1 + 1_000)
  #     ...> |> get(:Alice)
  #     1024
  #     iex> sleep(20)
  #     iex> ep
  #     ...> |> update(:Alice, fn nil -> 42 end)  # value is missing
  #     ...> |> get(:Alice)
  #     42

  #     iex> {:ok, ep} = ExPirate.start()
  #     iex> ep
  #     ...> |> update(:Bob, fn nil -> 42 end)    # value is missing
  #     ...> |> get(:Bob)
  #     42
  #     iex> sleep(20)
  #     iex> get(ep, :Bob)
  #     nil
  # """
  # @spec update(ep, key, (value | initial -> value), keyword | timeout) :: ep
  # def update(ep, key, fun, opts \\ [!: :avg]) do
  #   get_and_update(ep, key, &{ep, fun.(&1)}, opts)
  # end

  # # GET_AND_UPDATE

  # @doc """
  # Gets the value for `key` and updates it, all in one pass.

  # The `fun` is sent to an `AgentMap` that invokes it, passing the value for
  # `key`. A callback can return:

  #   * `{ret, new value}` — to set new value and retrive "ret";
  #   * `{ret}` — to retrive "ret" value;
  #   * `:pop` — to retrive current value and remove `key`;
  #   * `:id` — to just retrive current value.

  # For example, `get_and_update(account, :Alice, &{&1, &1 + 1_000_000})` returns
  # the balance of `:Alice` and makes the deposit, while `get_and_update(account,
  # :Alice, &{&1})` just returns the balance.

  # This call creates a temporary worker that is responsible for holding queue of
  # calls awaiting execution for `key`. If such a worker exists, call is added to
  # the end of its queue. Priority can be given (`:!`), to process call out of
  # turn.

  # See `Map.get_and_update/3`.

  # ## Options

  #   * `:initial`, `nil` — value for `key` if it's missing;

  #   * `tiny: true` — to execute `fun` in servers loop if it's possible;

  #   * `!: priority`, `:avg`;

  #   * `:timeout`, `5000`.

  # ## Examples

  #     iex> am = AgentMap.new(a: 42)
  #     ...>
  #     iex> get_and_update(am, :a, &{&1, &1 + 1})
  #     42
  #     iex> get(am, :a)
  #     43
  #     iex> get_and_update(am, :a, fn _ -> :pop end)
  #     43
  #     iex> has_key?(am, :a)
  #     false
  #     iex> get_and_update(am, :a, fn _ -> :id end)
  #     nil
  #     iex> has_key?(am, :a)
  #     false
  #     iex> get_and_update(am, :a, &{&1, &1})
  #     nil
  #     iex> has_key?(am, :a)
  #     true
  #     iex> get_and_update(am, :b, &{&1, &1}, initial: 42)
  #     42
  #     iex> has_key?(am, :b)
  #     true
  # """
  # @spec get_and_update(
  #         ep,
  #         key,
  #         (value | initial -> {ret} | {ret, value} | :pop | :id),
  #         keyword | timeout
  #       ) :: ret | value | initial
  #       when ret: var
  # def get_and_update(ep, key, fun, opts \\ [!: :avg])

  # def get_and_update(ep, key, fun, t) when is_timeout(t) do
  #   get_and_update(am, key, fun, timeout: t)
  # end

  # def get_and_update(ep, key, fun, opts) do
  #   initial = opts[:initial]
  #   opts = Keyword.put(opts, :initial, %{})

  #   interpret = fn
  #     {_get, _value} = ret ->
  #       stamp(ep, key, [:updated, :updated_at])
  #       ret

  #     :pop ->
  #       stamp(ep, key, [:updated, :updated_at])
  #       :pop

  #     ret ->
  #       ret
  #   end

  #   AgentMap.get_and_update(ep, key, fn ->
  #     %{value: v} = item ->
  #       ret =
  #         unless expired?(ep, item) do
  #           stamp(ep, key, [:used, :used_at])
  #           fun.(v)
  #         else
  #           fun.(initial)
  #         end

  #       interpret.(ret)

  #     _ ->
  #       stamp(ep, key, [:missed, :missed_at])
  #       interpret.(fun.(initial))
  #   end, opts)
  # end

  #
  ## PUT
  #

  @doc """
  Puts `value` under the `key`. Statistics is updated.

  Returns without waiting for the actual put.

  Default priority for this call is `:max`.

  ## Options

    * `expired?: (item -> boolean)`, `get_prop(ep, :expired?)` — a custom
      indicator that item is [expired](#module-expired-items);

    * `ttl: pos_integer`, `get_prop(ep, :ttl)` — period (in ms) counted from
      `:inserted_at` or `:updated_at`, during which this item considered as not
      expired;

    * `attrs: [attr] | nil`, `get_prop(ep, :attrs)` — custom attribute list for
      the `key`;

    * `cast: false` — to return after the actual put;

    * `!: priority`, `:max`;

    * `:timeout`, `5000`.

  ## Examples

      iex> {:ok, ep} =
      ...>   ExPirate.start(attrs: [:used])
      ...>
      iex> ep
      ...> |> put(:key, 42, expired?: & &1[:used] > 1)  # used: 0
      ...> |> get(:key)
      42                                                # used: 1
      iex> fetch(ep, :key)
      {:ok, 42}                                         # used: 2
      #
      iex> sleep(50)                                    # !
      iex> fetch(ep, :key)
      {:error, :expired}
      #
      iex> ep
      ...> |> put(:key, 43)
      ...> |> get(:key, raw: true)
      %{value: 43, used: 2}                             # used: 3
  """
  @spec put(ep, key, value, keyword | timeout) :: ep
  def put(ep, key, value, opts \\ [cast: true, !: :max])

  def put(ep, key, value, t) when is_timeout(t) do
    put(ep, key, value, timeout: t)
  end

  def put(ep, key, value, opts) do
    opts =
      opts
      |> Keyword.delete(:ttl, nil)
      |> Keyword.delete(:expired?, nil)
      |> Keyword.put_new(:!, :max)
      |> Keyword.put_new(:cast, true)
      |> Keyword.put_new(:tiny, true)

    item =
      opts
      |> Keyword.take([:ttl, :expired?, :attrs])
      |> Enum.into(%{value: value})

    #
    keys = Map.keys(item)

    if :ttl in keys && :expired? in keys do
      raise """
      :ttl and :expired? options cannot be used on the same key at the same time
      """
    end

    enrich = fn item, data ->
      item
      |> Map.delete(:ttl)
      |> Map.delete(:expired?)
      |> Map.merge(data)
    end

    #
    AgentMap.update(
      ep,
      key,
      fn
        # %{value: ^value} = it ->
        #   it
        #   |> enrich.(item)
        #   |> gc(ep)

        %{value: _} = it ->
          it
          |> enrich.(item)
          |> stamp(:updated)
          |> stamp(:updated_at)
          |> gc(ep)

        no_value ->
          no_value
          |> enrich.(item)
          |> stamp(:inserted_at)
          |> gc(ep)
      end,
      [{:initial, %{}} | opts]
    )
  end
end
