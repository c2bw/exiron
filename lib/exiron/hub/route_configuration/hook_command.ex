defmodule Exiron.Hub.RouteConfiguration.HookCommand do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Values

  @enforce_keys [:hook, :token]
  defstruct [:hook, :token]

  @type t :: %__MODULE__{hook: String.t(), token: String.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Exiron.Hub.RouteConfiguration.ValidationError.t()}
  def new(%__MODULE__{} = command), do: {:ok, command}

  def new(attributes) when is_map(attributes) do
    with {:ok, values} <-
           Values.validate(
             hook: Values.required_string(Values.get(attributes, "hook"), "hook is required"),
             token: Values.required_string(Values.get(attributes, "token"), "token is required")
           ) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(_attributes), do: Values.invalid_attributes()
end
