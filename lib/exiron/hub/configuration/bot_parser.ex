defmodule Exiron.Hub.Configuration.BotParser do
  @moduledoc false

  alias Exiron.Hub.BotName
  alias Exiron.Hub.RouteConfiguration.Document

  def parse(definitions) do
    with {:ok, entries} <- definitions |> Document.telegram_bots_value() |> validate_entries() do
      parse_entries(entries)
    end
  end

  defp validate_entries(entries) when is_list(entries), do: {:ok, entries}
  defp validate_entries(_entries), do: {:error, "telegram.bots must be a list"}

  defp parse_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], %{}}}, &parse_entry/2)
    |> finalize()
  end

  defp parse_entry({entry, index}, {:ok, {groups, aliases}}) do
    case bot(entry, index, aliases) do
      {:ok, entries, aliases} -> {:cont, {:ok, {[entries | groups], aliases}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize({:ok, {groups, aliases}}) do
    entries = groups |> Enum.reverse() |> List.flatten()

    with :ok <- validate_unique_bot_names(entries) do
      {:ok, {entries, aliases}}
    end
  end

  defp finalize(error), do: error

  defp bot(entry, index, aliases) when is_map(entry) do
    with {:ok, token} <- parse_token(Map.get(entry, "token"), index),
         {:ok, name} <- parse_name(Map.get(entry, "name"), index),
         {:ok, chats} <- parse_bot_chats(Map.get(entry, "chats"), index) do
      parse_chats(chats, index, token, name, aliases)
    end
  end

  defp bot(_entry, index, _aliases), do: {:error, "telegram bot #{index} must be an object"}

  defp parse_token(token, index) when is_binary(token) do
    case String.trim(token) do
      "" -> {:error, "telegram bot #{index} has an empty token"}
      token -> {:ok, token}
    end
  end

  defp parse_token(nil, index), do: {:error, "telegram bot #{index} has an empty token"}

  defp parse_token(_token, index),
    do: {:error, "telegram bot #{index} token must be a string"}

  defp parse_name(nil, _index), do: {:ok, nil}

  defp parse_name(name, _index) when is_binary(name) do
    case String.trim(name) do
      "" -> {:ok, nil}
      name -> {:ok, name}
    end
  end

  defp parse_name(_name, index),
    do: {:error, "telegram bot #{index} name must be a string"}

  defp parse_bot_chats(chats, _index) when is_map(chats), do: {:ok, chats}

  defp parse_bot_chats(_chats, index),
    do: {:error, "telegram bot #{index} chats must be a map"}

  defp parse_chats(chats, index, token, name, aliases) do
    chats
    |> Enum.reduce_while({:ok, {[], aliases}}, fn {alias, chat_id}, {:ok, {entries, aliases}} ->
      parse_chat(alias, chat_id, index, token, name, entries, aliases)
    end)
    |> case do
      {:ok, {entries, aliases}} -> {:ok, Enum.reverse(entries), aliases}
      error -> error
    end
  end

  defp parse_chat(alias, chat_id, index, token, name, entries, aliases)
       when is_binary(alias) do
    alias = String.trim(alias)

    cond do
      alias == "" ->
        {:halt, {:error, "telegram bot #{index} has an empty chat alias"}}

      not is_integer(chat_id) ->
        {:halt, {:error, "telegram bot #{index} chat #{inspect(alias)} must be an integer"}}

      Map.has_key?(aliases, alias) and Map.fetch!(aliases, alias) != chat_id ->
        {:halt, {:error, "telegram chat alias #{inspect(alias)} has conflicting IDs"}}

      true ->
        entry = %{bot_token: token, chat_id: chat_id, bot_name: name}
        {:cont, {:ok, {[entry | entries], Map.put(aliases, alias, chat_id)}}}
    end
  end

  defp parse_chat(_alias, _chat_id, index, _token, _name, _entries, _aliases) do
    {:halt, {:error, "telegram bot #{index} chat aliases must be strings"}}
  end

  defp validate_unique_bot_names(entries) do
    entries
    |> Enum.reduce_while(%{}, fn
      %{bot_name: bot_name, bot_token: bot_token, chat_id: chat_id}, names
      when is_binary(bot_name) ->
        normalized = BotName.normalize(bot_name)
        key = {chat_id, normalized}

        case Map.fetch(names, key) do
          {:ok, ^bot_token} ->
            {:cont, names}

          {:ok, _other_token} ->
            {:halt,
             {:error,
              "telegram bot name #{inspect(normalized)} must be unique for chat #{chat_id}"}}

          :error ->
            {:cont, Map.put(names, key, bot_token)}
        end

      _entry, names ->
        {:cont, names}
    end)
    |> case do
      {:error, _reason} = error -> error
      _names -> :ok
    end
  end
end
