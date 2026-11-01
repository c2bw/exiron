defmodule Exiron.Hub.RouteConfiguration.TelegramProjection do
  @moduledoc false

  alias Exiron.Hub.Telegram

  def bots(configs, aliases) do
    aliases_by_chat_id = aliases_by_chat_id(aliases)

    configs
    |> Enum.group_by(& &1.bot_token)
    |> Enum.sort_by(fn {token, _configs} -> token end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{token, configs}, index} ->
      bot_summary(index, token, configs, aliases_by_chat_id)
    end)
  end

  defp bot_summary(index, token, configs, aliases_by_chat_id) do
    chat_ids = configs |> Enum.map(& &1.chat_id) |> Enum.uniq() |> Enum.sort()
    chats = Enum.map(chat_ids, &%{id: &1, aliases: Map.get(aliases_by_chat_id, &1, [])})
    bot_name = Enum.find_value(configs, & &1.bot_name)

    %{
      id: index,
      chats: chats,
      chat_aliases: chats |> Enum.flat_map(& &1.aliases) |> Enum.uniq() |> Enum.sort(),
      chat_ids: chat_ids,
      chat_count: length(chat_ids),
      bot_name: bot_name,
      bot_tag: Telegram.bot_tag(bot_name),
      bot_tag_source: if(is_binary(bot_name), do: :config, else: nil),
      token_fingerprint: Telegram.token_fingerprint(token)
    }
  end

  defp aliases_by_chat_id(aliases) do
    aliases
    |> Enum.group_by(fn {_alias, chat_id} -> chat_id end, fn {alias, _chat_id} -> alias end)
    |> Map.new(fn {chat_id, names} -> {chat_id, Enum.sort(names)} end)
  end
end
