defmodule Exiron.Hub.Telegram.MembershipEvent do
  @moduledoc false

  def from_update(update, opts) do
    old_status = update |> get_in_map([:old_chat_member, :status]) |> normalize_status()
    new_status = update |> get_in_map([:new_chat_member, :status]) |> normalize_status()
    action = action(old_status, new_status)
    chat_id = get_in_map(update, [:chat, :id])

    if action && is_integer(chat_id) do
      %{
        action: action,
        chat_id: chat_id,
        chat_title: get_in_map(update, [:chat, :title]),
        bot_token: Keyword.fetch!(opts, :bot_token),
        bot_name: bot_name(update, Keyword.get(opts, :bot_name)),
        bot_user_id: get_in_map(update, [:new_chat_member, :user, :id]),
        old_status: old_status,
        new_status: new_status
      }
    end
  end

  defp action(old_status, new_status) do
    cond do
      inactive?(old_status) and active?(new_status) -> "added"
      active?(old_status) and inactive?(new_status) -> "removed"
      true -> nil
    end
  end

  defp bot_name(_update, bot_name) when is_binary(bot_name) and bot_name != "", do: bot_name

  defp bot_name(update, _bot_name) do
    case get_in_map(update, [:new_chat_member, :user, :username]) do
      username when is_binary(username) and username != "" -> username
      _username -> nil
    end
  end

  defp active?(status), do: status in ["creator", "administrator", "member", "restricted"]
  defp inactive?(status), do: status in [nil, "left", "kicked"]
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(_status), do: nil

  defp get_in_map(data, keys) do
    Enum.reduce_while(keys, data, fn key, acc ->
      case map_fetch(acc, key) do
        {:ok, value} -> {:cont, value}
        :error -> {:halt, nil}
      end
    end)
  end

  defp map_fetch(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        {:ok, Map.fetch!(map, Atom.to_string(key))}

      true ->
        :error
    end
  end

  defp map_fetch(_map, _key), do: :error
end
