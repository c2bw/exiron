defmodule Exiron.Hub.RouteConfiguration.MiddlewareRouteCommand do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Values

  @enforce_keys [:middleware, :hook, :messages]
  defstruct [:middleware, :hook, :messages, passthrough: false]

  @type t :: %__MODULE__{
          middleware: String.t(),
          hook: String.t(),
          messages: [String.t()],
          passthrough: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Exiron.Hub.RouteConfiguration.ValidationError.t()}
  def new(%__MODULE__{} = command), do: {:ok, command}

  def new(attributes) when is_map(attributes) do
    with {:ok, values} <-
           Values.validate(
             middleware:
               Values.required_string(
                 Values.get(attributes, "middleware"),
                 "middleware is required"
               ),
             hook: Values.required_string(Values.get(attributes, "hook"), "hook is required"),
             messages:
               Values.csv_list(Values.get(attributes, "messages"))
               |> case do
                 [] -> {:error, "messages are required"}
                 messages -> {:ok, messages}
               end
           ) do
      {:ok,
       struct!(
         __MODULE__,
         Map.put(values, :passthrough, Values.truthy?(Values.get(attributes, "passthrough")))
       )}
    end
  end

  def new(_attributes), do: Values.invalid_attributes()
end
