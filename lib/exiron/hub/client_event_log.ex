defmodule Exiron.Hub.ClientEventLog do
  @moduledoc false

  alias Exiron.Hub.{DeliveryHealth, History, Identifier}

  @max_events 100

  def record(state, action, hook, client) do
    record(state, action, hook, client, Identifier.new())
  end

  def record(state, action, hook, client, event_id) do
    event = event_payload(action, hook, client, event_id)

    activity = %{
      state.activity
      | client_events: History.prepend(state.activity.client_events, event, @max_events)
    }

    state
    |> Map.put(:activity, activity)
    |> DeliveryHealth.connected(hook, action, event.at)
  end

  defp event_payload(action, hook, client, event_id) do
    %{
      id: event_id,
      at: DateTime.utc_now(),
      action: action,
      hook: hook,
      client_id: client.client_id,
      listening: client.listen?
    }
  end
end
