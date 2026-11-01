defmodule Exiron.Hub.RouteConfiguration.Mutator do
  @moduledoc false

  alias Exiron.Hub.HookToken
  alias Exiron.Hub.RouteConfiguration.{Document, Encoder, TelegramChatAliases}
  alias Exiron.Hub.RouteConfiguration.{ChatRouteCommand, HookCommand, MiddlewareRouteCommand}
  alias Exiron.Hub.RouteConfiguration.TelegramBotCommand
  alias Exiron.Hub.RouteConfiguration.ValidationError
  import Exiron.Hub.RouteConfiguration.Values, only: [map_or_empty: 1]

  def put_chat_route(source, attrs) do
    update_source(source, fn definitions ->
      with {:ok, command} <- ChatRouteCommand.new(attrs),
           {:ok, definitions} <-
             TelegramChatAliases.put(
               definitions,
               command.alias,
               command.chat_id,
               command.bot_token
             ) do
        route = %{
          "middleware" => command.middleware,
          "push" => command.push
        }

        {:ok, put_in(definitions, ["routes", command.alias], route)}
      end
    end)
  end

  def put_telegram_bot(source, attrs) do
    update_source(source, fn definitions ->
      with {:ok, command} <- TelegramBotCommand.new(attrs) do
        bot =
          %{"token" => command.bot_token, "chats" => %{command.alias => command.chat_id}}
          |> maybe_put("name", command.bot_name)

        {:ok, update_in(definitions, ["telegram", "bots"], &((&1 || []) ++ [bot]))}
      end
    end)
  end

  def put_middleware_route(source, attrs) do
    update_source(source, fn definitions ->
      with {:ok, command} <- MiddlewareRouteCommand.new(attrs) do
        route =
          definitions
          |> get_in(["middlewares", command.middleware, "routes", command.hook])
          |> map_or_empty()
          |> Map.take(["interaction"])
          |> Map.put("messages", command.messages)
          |> maybe_put_boolean("passthrough", command.passthrough)

        {:ok,
         put_path(
           definitions,
           ["middlewares", command.middleware, "routes", command.hook],
           route
         )}
      end
    end)
  end

  def put_hook(source, attrs) do
    update_source(source, fn definitions ->
      with {:ok, command} <- HookCommand.new(attrs) do
        {:ok, put_in(definitions, ["hooks", command.hook], HookToken.hash(command.token))}
      end
    end)
  end

  defp update_source(source, fun) do
    with {:ok, definitions} <- read_definitions(source),
         {:ok, definitions} <- fun.(definitions) do
      {:ok, Encoder.encode(definitions)}
    else
      {:error, %ValidationError{} = error} -> {:error, ValidationError.message(error)}
      error -> error
    end
  end

  defp read_definitions(source) do
    with {:ok, definitions} <- YamlElixir.read_from_string(source) do
      {:ok, Document.ensure_supported_sections(definitions)}
    end
  end

  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    child =
      map
      |> Map.get(key)
      |> map_or_empty()
      |> put_path(rest, value)

    Map.put(map, key, child)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_boolean(map, key, true), do: Map.put(map, key, true)
  defp maybe_put_boolean(map, _key, _value), do: map
end
