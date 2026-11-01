defmodule Exiron.Hub.RouteConfiguration.TelegramChatAliases do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.Document

  import Exiron.Hub.RouteConfiguration.Values, only: [map_or_empty: 1]

  def put(definitions, alias, chat_id, bot_token) do
    bots = Document.telegram_bots(definitions)

    case put_in_bot(bots, alias, chat_id, bot_token) do
      {:ok, bots} -> {:ok, put_in(definitions, ["telegram", "bots"], bots)}
      :error -> {:error, "telegram bot is required before adding chat routes"}
      :ambiguous -> {:error, "bot token is required when multiple Telegram bots are configured"}
      :not_found -> {:error, "telegram bot token was not found"}
    end
  end

  defp put_in_bot(bots, alias, chat_id, nil) do
    case Enum.filter(bots, &has_chat_id?(&1, chat_id)) do
      [bot] ->
        replace_bot(bots, bot, alias, chat_id)

      [] ->
        put_in_only_bot(bots, alias, chat_id)

      _bots ->
        :ambiguous
    end
  end

  defp put_in_bot(bots, alias, chat_id, bot_token) do
    case Enum.find(bots, &token?(&1, bot_token)) do
      nil -> :not_found
      bot -> replace_bot(bots, bot, alias, chat_id)
    end
  end

  # An existing chat identifies its bot. A new chat is implicit only when one
  # valid bot is configured; otherwise callers must provide the bot token.
  defp put_in_only_bot(bots, alias, chat_id) do
    case Enum.filter(bots, &is_map/1) do
      [bot] -> replace_bot(bots, bot, alias, chat_id)
      [] -> :error
      _bots -> :ambiguous
    end
  end

  defp replace_bot(bots, target, alias, chat_id) do
    {:ok,
     Enum.map(bots, fn
       ^target -> update_in(target, ["chats"], &(map_or_empty(&1) |> Map.put(alias, chat_id)))
       bot -> bot
     end)}
  end

  defp has_chat_id?(bot, chat_id) when is_map(bot) do
    bot
    |> Map.get("chats")
    |> map_or_empty()
    |> Enum.any?(fn {_alias, id} -> id == chat_id end)
  end

  defp has_chat_id?(_bot, _chat_id), do: false

  defp token?(bot, token) when is_map(bot), do: Map.get(bot, "token") == token
  defp token?(_bot, _token), do: false
end
