defmodule Exiron.Hub.Status do
  @moduledoc false

  alias Exiron.Hub.{DeliveryHealth, QueueState, Router}
  alias Exiron.Hub.Status.Telegram, as: TelegramStatus

  @sensitive_keys [:bot_token, "bot_token"]

  def snapshot(%{enabled?: true} = state, version) do
    hooks = QueueState.hook_snapshots(state)
    suppression = Exiron.Hub.Telegram.SendCoordinator.snapshot()

    version
    |> disabled_snapshot()
    |> Map.merge(TelegramStatus.snapshot(state))
    |> Map.merge(%{
      enabled: true,
      drain: Exiron.Hub.Drain.snapshot(state),
      buffer_capacity: Exiron.Hub.BufferBudget.snapshot(state),
      send_capacity: Exiron.Hub.SendBudget.snapshot(state),
      telegram_suppression: Map.delete(suppression, :records),
      suppressed_bots: suppression.records,
      requested: map_size(state.delivery.pending),
      hooks: hooks,
      delivery_health: DeliveryHealth.summary(hooks),
      routes: Router.snapshot(state.router),
      events: state.activity.events,
      send_failures: state.activity.send_failures,
      overload_events: state.activity.overload_events,
      membership_events: state.activity.membership_events,
      bot_memberships: Map.values(state.activity.bot_memberships),
      client_events: state.activity.client_events,
      revision: state.publication.revision
    })
    |> redact_sensitive_fields()
  end

  def snapshot(_state, version), do: disabled_snapshot(version)

  def snapshot_for_hook(%{enabled?: true} = state, version, hook) do
    hooks = QueueState.hook_snapshots(state, hook)
    routes = Router.snapshot_for_hook(state.router, hook)
    chat_ids = routes |> Enum.map(& &1.chat_id) |> MapSet.new()

    version
    |> disabled_snapshot()
    |> Map.drop([:buffer_capacity, :send_capacity, :telegram_suppression, :suppressed_bots])
    |> Map.merge(TelegramStatus.snapshot_for_routes(state, routes))
    |> Map.merge(%{
      enabled: true,
      requested: pending_count(state.delivery.pending, hook),
      hooks: hooks,
      delivery_health: DeliveryHealth.summary(hooks),
      routes: routes,
      events: filter_hook(state.activity.events, hook),
      send_failures: filter_hook(state.activity.send_failures, hook),
      overload_events: filter_hook(state.activity.overload_events, hook),
      membership_events: filter_chats(state.activity.membership_events, chat_ids),
      bot_memberships: filter_chats(Map.values(state.activity.bot_memberships), chat_ids),
      client_events: filter_hook(state.activity.client_events, hook),
      revision: state.publication.revision
    })
    |> redact_sensitive_fields()
  end

  def snapshot_for_hook(_state, version, _hook),
    do:
      version
      |> disabled_snapshot()
      |> Map.drop([:buffer_capacity, :send_capacity, :telegram_suppression, :suppressed_bots])

  def client_poll_changed?(previous_state, next_state) do
    poll_snapshot(previous_state) != poll_snapshot(next_state) or
      previous_state.activity.client_events != next_state.activity.client_events
  end

  # Idle contact timestamps are read on demand by API callers and the monitor's
  # clock. They must not publish a full status update for every empty poll.
  defp poll_snapshot(state) do
    Enum.map(QueueState.hook_snapshots(state), fn hook ->
      Map.update!(hook, :client, &Map.drop(&1, [:last_contact_at, :last_contact_kind, :runtime]))
    end)
  end

  defp disabled_snapshot(version) do
    %{
      enabled: false,
      drain: nil,
      buffer_capacity: nil,
      send_capacity: nil,
      telegram_suppression: nil,
      suppressed_bots: [],
      telegram_polling: false,
      telegram_last_polled_at: nil,
      version: version,
      requested: 0,
      delivery_health: DeliveryHealth.summary([]),
      chats: [],
      hooks: [],
      routes: [],
      events: [],
      send_failures: [],
      overload_events: [],
      membership_events: [],
      bot_memberships: [],
      client_events: [],
      revision: 0
    }
  end

  defp pending_count(pending, hook) do
    Enum.count(pending, fn {_request_id, request} -> request.hook == hook end)
  end

  defp filter_hook(items, hook), do: Enum.filter(items, &(Map.get(&1, :hook) == hook))

  defp filter_chats(items, chat_ids) do
    Enum.filter(items, &MapSet.member?(chat_ids, Map.get(&1, :chat_id)))
  end

  defp redact_sensitive_fields(%_{} = struct), do: struct

  defp redact_sensitive_fields(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, redact_sensitive_fields(value)} end)
    |> Map.drop(@sensitive_keys)
  end

  defp redact_sensitive_fields(list) when is_list(list),
    do: Enum.map(list, &redact_sensitive_fields/1)

  defp redact_sensitive_fields(value), do: value
end
