defmodule Exiron.Hub.SendResultsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{DeliveryState, Effect, Message, SendCommand, SendResults, Telegram}

  test "successful responses reply, remove pending ownership, and record an event" do
    {state, operation, from, timer} = response_operation()

    transition = SendResults.complete(state, operation, :ok)
    next_state = transition.next_state

    assert [
             %Effect{kind: :cancel_timer},
             %Effect{kind: :reply, payload: {^from, :ok}},
             %Effect{kind: :broadcast_status}
           ] = transition.effects

    refute Map.has_key?(next_state.delivery.pending, "request-1")
    assert [%{kind: "response", hook: "assistant"}] = next_state.activity.events
    assert Process.read_timer(timer)
    Process.cancel_timer(timer)
  end

  test "retryable response failures retain pending ownership and clear the in-flight marker" do
    {state, operation, from, timer} = response_operation()

    transition = SendResults.complete(state, operation, {:error, :telegram_unavailable})
    next_state = transition.next_state

    assert [
             %Effect{kind: :reply, payload: {^from, {:error, :telegram_unavailable}}},
             %Effect{kind: :broadcast_status}
           ] = transition.effects

    assert next_state.delivery.pending["request-1"].claimed?
    refute Map.has_key?(next_state.delivery.pending["request-1"], :responding?)

    assert [%{operation: "reply", reason: "{:error, :telegram_unavailable}"}] =
             next_state.activity.send_failures

    assert Process.read_timer(timer)
    Process.cancel_timer(timer)
  end

  test "response timeouts reply, release pending ownership, and record failure context" do
    {state, operation, from, timer} = response_operation()

    transition = SendResults.timeout(state, operation)
    next_state = transition.next_state

    assert [
             %Effect{kind: :cancel_timer},
             %Effect{kind: :reply, payload: {^from, {:error, :telegram_delivery_timeout}}},
             %Effect{kind: :broadcast_status}
           ] = transition.effects

    refute Map.has_key?(next_state.delivery.pending, "request-1")
    assert [%{kind: "response_failed", hook: "assistant"}] = next_state.activity.events

    assert [%{operation: "reply", reason: ":telegram_delivery_timeout"}] =
             next_state.activity.send_failures

    assert Process.read_timer(timer)
    Process.cancel_timer(timer)
  end

  test "response authorization failures are terminal and record a failed event" do
    {state, operation, from, timer} = response_operation()
    forbidden = %ExGram.Error{code: 403, message: "Forbidden"}

    transition = SendResults.complete(state, operation, {:error, forbidden})
    next_state = transition.next_state

    assert [
             %Effect{kind: :cancel_timer},
             %Effect{kind: :reply, payload: {^from, {:error, :telegram_bot_forbidden}}},
             %Effect{kind: :broadcast_status}
           ] = transition.effects

    refute Map.has_key?(next_state.delivery.pending, "request-1")
    assert [%{kind: "response_failed", hook: "assistant"}] = next_state.activity.events

    assert [%{operation: "reply", reason: ":telegram_bot_forbidden"}] =
             next_state.activity.send_failures

    assert Process.read_timer(timer)
    Process.cancel_timer(timer)
  end

  test "push authorization failures are normalized for API error handling" do
    from = {self(), make_ref()}
    operation = SendCommand.push(from, "assistant")
    state = %State{}

    unauthorized = %ExGram.Error{code: 401, message: "Unauthorized"}

    transition = SendResults.complete(state, operation, {:partial_error, unauthorized, []})

    assert %Effect{kind: :reply, payload: {^from, {:error, :telegram_bot_unauthorized}}} =
             hd(transition.effects)

    assert state == transition.next_state
  end

  test "partial pushes record successful sends and individual failures" do
    from = {self(), make_ref()}
    operation = SendCommand.push(from, "assistant")

    state = %State{
      telegram: Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "assistant-bot"}])
    }

    sent = Message.new(222, 123, "text", "sent", "bot-token")
    failed = Message.new(222, 123, "text", "failed", "bot-token")

    transition =
      SendResults.complete(
        state,
        operation,
        {:partial_error, :telegram_unavailable, [sent], [{failed, :telegram_unavailable}]}
      )

    next_state = transition.next_state

    assert [
             %Effect{kind: :reply, payload: {^from, {:error, :telegram_unavailable}}},
             %Effect{kind: :broadcast_status}
           ] = transition.effects

    assert [%{kind: "push", preview: "sent"}] = next_state.activity.events

    assert [%{operation: "push", preview: "failed", reason: ":telegram_unavailable"}] =
             next_state.activity.send_failures
  end

  defp response_operation do
    timer = Process.send_after(self(), :pending_expired, 10_000)
    reply_tag = make_ref()
    from = {self(), reply_tag}

    message =
      Message.new(222, 123, "text", "reply", "bot-token", bot_name: "assistant-bot")

    pending = %{
      service_id: 222,
      chat_id: 123,
      bot_token: "bot-token",
      bot_name: "assistant-bot",
      hook: "assistant",
      timer: timer,
      claimed?: true,
      responding?: true
    }

    state = %State{
      enabled?: true,
      telegram:
        Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "assistant-bot"}]),
      delivery: %DeliveryState{pending: %{"request-1" => pending}}
    }

    operation = SendCommand.respond(from, "request-1", pending, "assistant", message)
    {state, operation, from, timer}
  end
end
