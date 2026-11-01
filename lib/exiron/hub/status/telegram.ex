defmodule Exiron.Hub.Status.Telegram do
  @moduledoc false

  alias Exiron.Hub.Router
  alias Exiron.Hub.Telegram, as: HubTelegram

  def snapshot(%{router: router, telegram: %HubTelegram{} = telegram} = state) do
    routes = Router.snapshot(router)
    configs = HubTelegram.configs(telegram)

    chat_ids =
      routes
      |> Enum.map(& &1.chat_id)
      |> Kernel.++(Enum.map(configs, & &1.chat_id))
      |> Enum.uniq()
      |> Enum.sort()

    chats = chat_snapshots(state, routes, configs, chat_ids, state.telegram_last_polled_at)
    status_snapshot(chats, state.telegram_last_polled_at, polling?(state))
  end

  def snapshot(state) do
    %{
      telegram_polling: false,
      telegram_last_polled_at: Map.get(state, :telegram_last_polled_at),
      chats: []
    }
  end

  def snapshot_for_routes(%{telegram: %HubTelegram{} = telegram} = state, routes)
      when is_list(routes) do
    configs = HubTelegram.configs(telegram)
    chat_ids = routes |> Enum.map(& &1.chat_id) |> Enum.uniq() |> Enum.sort()
    chats = chat_snapshots(state, routes, configs, chat_ids, nil)

    status_snapshot(chats, nil, chats != [] and Enum.all?(chats, & &1.polling))
  end

  def snapshot_for_routes(_state, _routes) do
    %{telegram_polling: false, telegram_last_polled_at: nil, chats: []}
  end

  defp status_snapshot(chats, last_polled_at, telegram_polling) do
    %{
      telegram_polling: telegram_polling,
      telegram_last_polled_at: last_polled_at,
      chats: chats
    }
  end

  defp chat_snapshots(state, routes, configs, chat_ids, last_polled_at) do
    routes_by_chat_id = Enum.group_by(routes, & &1.chat_id)
    configs_by_chat_id = Enum.group_by(configs, & &1.chat_id)
    current_bot_by_chat_id = current_bot_by_chat_id(state.activity.events)

    chat_ids
    |> Enum.map(fn chat_id ->
      routes = Map.get(routes_by_chat_id, chat_id, [])
      configs = Map.get(configs_by_chat_id, chat_id, [])
      default_bot = default_bot(routes, state.telegram, chat_id)

      %{
        id: chat_id,
        aliases: aliases(routes),
        default_bot: default_bot,
        current_bot: Map.get(current_bot_by_chat_id, chat_id, default_bot),
        bot_memberships: bot_memberships(state.activity.bot_memberships, chat_id),
        polling: chat_polling?(state, configs),
        last_polled_at: last_polled_at
      }
    end)
  end

  defp polling?(%{telegram_pollers_enabled?: true, telegram: %HubTelegram{} = telegram} = state) do
    pollers_available?(HubTelegram.poller_tokens(telegram), state)
  end

  defp polling?(_state), do: false

  defp chat_polling?(%{telegram_pollers_enabled?: true} = state, configs) do
    configs
    |> Enum.map(& &1.bot_token)
    |> Enum.uniq()
    |> pollers_available?(state)
  end

  defp chat_polling?(_state, _configs), do: false

  defp pollers_available?([], _state), do: false

  defp pollers_available?(tokens, state) do
    pollers = Map.get(state, :telegram_pollers, %{})
    Enum.all?(tokens, &Map.has_key?(pollers, &1))
  end

  defp aliases(routes) do
    routes
    |> Enum.map(& &1.chat_alias)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Event history is newest-first, so the first bot observed per chat is current.
  defp current_bot_by_chat_id(events) do
    Enum.reduce(events, %{}, fn
      %{chat_id: chat_id, bot_name: bot_name}, acc
      when is_integer(chat_id) and is_binary(bot_name) ->
        Map.put_new(acc, chat_id, bot_name)

      _event, acc ->
        acc
    end)
  end

  defp default_bot(routes, telegram, chat_id) do
    Enum.find_value(routes, & &1.default_bot) || HubTelegram.default_bot_name(telegram, chat_id)
  end

  defp bot_memberships(memberships, chat_id) do
    memberships
    |> Enum.filter(fn {{membership_chat_id, _token}, _membership} ->
      membership_chat_id == chat_id
    end)
    |> Enum.map(fn {_key, membership} -> membership end)
    |> Enum.sort_by(fn membership -> {membership.bot_name || "", membership.bot_user_id || 0} end)
  end
end
