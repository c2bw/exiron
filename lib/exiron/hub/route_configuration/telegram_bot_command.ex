defmodule Exiron.Hub.RouteConfiguration.TelegramBotCommand do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Values

  @enforce_keys [:bot_token, :chat_id, :alias]
  defstruct [:bot_token, :chat_id, :alias, :bot_name]

  @type t :: %__MODULE__{
          bot_token: String.t(),
          chat_id: integer(),
          alias: String.t(),
          bot_name: String.t() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, Exiron.Hub.RouteConfiguration.ValidationError.t()}
  def new(%__MODULE__{} = command), do: {:ok, command}

  def new(attributes) when is_map(attributes) do
    with {:ok, values} <-
           Values.validate(
             bot_token:
               Values.required_string(
                 Values.get(attributes, "bot_token"),
                 "bot token is required"
               ),
             chat_id: Values.chat_id(Values.get(attributes, "chat_id")),
             alias:
               Values.required_string(Values.get(attributes, "alias"), "chat alias is required")
           ) do
      {:ok,
       struct!(
         __MODULE__,
         Map.put(values, :bot_name, Values.optional_string(Values.get(attributes, "bot_name")))
       )}
    end
  end

  def new(_attributes), do: Values.invalid_attributes()
end
