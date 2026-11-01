defmodule Exiron.Hub.RouteConfiguration.ChatRouteCommand do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Values

  @enforce_keys [:alias, :chat_id, :bot_token, :middleware, :push]
  defstruct [:alias, :chat_id, :bot_token, :middleware, :push]

  @type t :: %__MODULE__{
          alias: String.t(),
          chat_id: integer(),
          bot_token: String.t() | nil,
          middleware: [String.t()],
          push: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, Exiron.Hub.RouteConfiguration.ValidationError.t()}
  def new(%__MODULE__{} = command), do: {:ok, command}

  def new(attributes) when is_map(attributes) do
    with {:ok, values} <-
           Values.validate(
             alias:
               Values.required_string(Values.get(attributes, "alias"), "chat alias is required"),
             chat_id: Values.chat_id(Values.get(attributes, "chat_id"))
           ) do
      {:ok,
       struct!(
         __MODULE__,
         values
         |> Map.put(:bot_token, Values.optional_string(Values.get(attributes, "bot_token")))
         |> Map.put(:middleware, Values.csv_list(Values.get(attributes, "middleware")))
         |> Map.put(:push, Values.truthy?(Values.get(attributes, "push")))
       )}
    end
  end

  def new(_attributes), do: Values.invalid_attributes()
end
