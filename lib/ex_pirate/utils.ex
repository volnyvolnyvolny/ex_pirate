defmodule ExPirate.Utils do
  #
  @type ep :: ExPirate.ep()
  @type item :: ExPirate.item()
  @type attr :: ExPirate.attr()
  @type custom :: ExPirate.custom()

  #
  defp now(), do: System.monotonic_time()

  # GET_PROP, UPD_PROP, SET_PROP

  @doc """
  Returns `:ttl`, `:expired?`, `:attrs` or a custom property using
  `AgentMap.Utils.get_prop/2`.
  """
  @spec get_prop(ep, :attrs) :: [attr]
  @spec get_prop(ep, :expired?) :: (item -> boolean) | nil
  @spec get_prop(ep, :ttl) :: pos_integer | nil
  @spec get_prop(ep, custom) :: term
  def get_prop(ep, p) when p in [:attrs, :keys] do
    AgentMap.Utils.get_prop(ep, p) || []
  end

  def get_prop(ep, p) do
    AgentMap.Utils.get_prop(ep, p)
  end

  #

  @doc """
  Update given property using `AgentMap.Utils.upd_prop/3`.

  To change `:expired?`, `:ttl` or `:attrs` use `set_prop/3`.

  ## Examples

      iex> {:ok, ep} = ExPirate.start()
      iex> ep
      ...> |> set_prop(:custom, 42)
      ...> |> upd_prop(:custom, & &1 * 2)
      ...> |> get_prop(:custom)
      84
  """
  @spec upd_prop(ep, custom, (term -> term)) :: ep
  def upd_prop(ep, prop, fun)

  def upd_prop(_ep, prop, _fun) when prop in [:expired?, :ttl, :attrs] do
    raise "Use set_prop/3 to update #{inspect(prop)}."
  end

  def upd_prop(_ep, :keys, _fun) do
    raise "Cannot update :keys prop."
  end

  def upd_prop(ep, prop, fun) do
    AgentMap.Utils.upd_prop(ep, prop, fun)
  end

  #

  @doc """
  Stores property using `AgentMap.Utils.set_prop/3`.

  Supported `:expired?`, `:ttl`, `:attrs` and any custom property.

  Be aware that setting `:expired?` deletes `:ttl` and vice versa.

  ## Examples

      iex> {:ok, ep} = ExPirate.start(ttl: 30)
      iex> get_prop(ep, :ttl)
      30
      iex> ep
      ...> |> set_prop(:ttl, 50)
      ...> |> get_prop(:ttl)
      50
      iex> ep
      ...> |> set_prop(:custom, "some param")
      ...> |> get_prop(:custom)
      "some param"
  """
  @spec set_prop(ep, :expired?, (item -> boolean) | nil) :: ep
  @spec set_prop(ep, :ttl, pos_integer | nil) :: ep
  @spec set_prop(ep, :attrs, [attr]) :: ep
  @spec set_prop(ep, custom, term) :: ep
  def set_prop(ep, :attrs, nil) do
    set_prop(ep, :attrs, [])
  end

  def set_prop(ep, :attrs, list) do
    AgentMap.Utils.set_prop(ep, :attrs, Enum.uniq(list))
  end

  def set_prop(ep, :ttl, t) do
    ep
    |> AgentMap.Utils.set_prop(:ttl, t)
    |> AgentMap.Utils.set_prop(:expired?, nil)
    |> AgentMap.Utils.set_prop(:inserted_at, now())
  end

  def set_prop(ep, :expired?, e) do
    ep
    |> AgentMap.Utils.set_prop(:expired?, e)
    |> AgentMap.Utils.set_prop(:ttl, nil)
  end

  def set_prop(ep, prop, value) do
    upd_prop(ep, prop, fn _ -> value end)
  end
end
