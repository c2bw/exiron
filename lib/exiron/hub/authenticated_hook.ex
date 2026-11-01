defmodule Exiron.Hub.AuthenticatedHook do
  @moduledoc false

  @enforce_keys [:name]
  @derive {Inspect, only: [:name]}
  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  def new(name) when is_binary(name), do: %__MODULE__{name: name}
end
