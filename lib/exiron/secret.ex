defmodule Exiron.Secret do
  @moduledoc false

  @derive {Inspect, only: []}
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  def new(%__MODULE__{} = secret), do: secret
  def new(value), do: %__MODULE__{value: value}
  def reveal(%__MODULE__{value: value}), do: value
  def reveal(value), do: value
end
