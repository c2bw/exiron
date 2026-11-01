defmodule Exiron.Hub.Runtime do
  @moduledoc false

  alias Exiron.Hub.{EventLog, History, Identifier, Message, Telegram}

  @max_send_failures 50

  def record_event(state, direction, target, hook, %Message{} = message, kind) do
    EventLog.record(state, direction, target, hook, message, kind, Identifier.new())
  end

  def record_send_failure(state, operation, hook, %Message{} = message, reason) do
    failure = %{
      id: Identifier.new(),
      at: DateTime.utc_now(),
      operation: operation,
      hook: hook,
      chat_id: message.chat_id,
      bot_name: message.bot_name,
      datatype: message.datatype,
      preview: EventLog.preview(message),
      reason: failure_reason(state, reason, message.bot_token)
    }

    activity = %{
      state.activity
      | send_failures: History.prepend(state.activity.send_failures, failure, @max_send_failures)
    }

    %{state | activity: activity}
  end

  def record_events(state, events) do
    Enum.reduce(events, state, &record_event_entry/2)
  end

  def record_push_events(state, hook, messages) do
    Enum.reduce(messages, state, fn message, acc ->
      record_event(acc, "outgoing", "telegram", hook, message, "push")
    end)
  end

  defp record_event_entry(event, state) do
    record_event(state, event.direction, event.target, event.hook, event.message, event.kind)
  end

  defp failure_reason(state, reason, message_bot_token) do
    state
    |> configured_bot_tokens()
    |> then(&[message_bot_token | &1])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.reduce(inspect(reason), &String.replace(&2, &1, "[REDACTED]"))
  end

  defp configured_bot_tokens(%{telegram: %Telegram{} = telegram}),
    do: Telegram.poller_tokens(telegram)

  defp configured_bot_tokens(_state), do: []
end
