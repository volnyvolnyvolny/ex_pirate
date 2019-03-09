defmodule ValueError do
  defexception [:key, :reason]

  @impl true
  def message(%{key: k, reason: :expired}) do
    "value for the key #{inspect(k)} is expired"
  end

  def message(%{key: k, reason: :missing}) do
    "value for the key #{inspect(k)} is missing"
  end
end
