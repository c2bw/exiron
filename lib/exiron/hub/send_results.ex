defmodule Exiron.Hub.SendResults do
  @moduledoc false

  alias Exiron.Hub.{
    Effect,
    DeliveryHealth,
    PendingRequests,
    RecentReplies,
    Runtime,
    SendCommand,
    SendResult,
    Telegram,
    Transition
  }

  @telegram_auth_failure_codes [401, 403]

  def timeout(state, operation) do
    command = operation

    case command.kind do
      :respond ->
        terminal_response_failure(state, command, :telegram_delivery_timeout)

      kind when kind in [:action, :edit] ->
        state = clear_auxiliary(state, command, :telegram_delivery_timeout)

        Transition.new(state,
          effects: [Effect.reply(command.from, {:error, :telegram_delivery_timeout})]
        )

      :push ->
        Transition.new(state,
          effects: [reply_push(command, {:error, :telegram_delivery_timeout})]
        )

      kind when kind in [:unavailable, :overloaded, :interaction] ->
        Transition.new(state)
    end
  end

  def complete(state, operation, result) do
    command = operation
    result = normalize_result(command, result)

    case {command.kind, result.status} do
      {:respond, :ok} ->
        complete_response(state, command, result.value)

      {kind, :ok} when kind in [:action, :edit] ->
        complete_auxiliary(state, command, result.value || command.message)

      {kind, :error} when kind in [:action, :edit] ->
        state = clear_auxiliary(state, command, result.reason)

        response =
          case result.reason do
            %ExGram.Error{code: code} when code in @telegram_auth_failure_codes ->
              {:error, telegram_delivery_error(code)}

            _ ->
              result.original || {:error, result.reason}
          end

        Transition.new(state,
          effects: [
            Effect.reply(command.from, response),
            Effect.broadcast_status()
          ]
        )

      {:respond, :error} ->
        complete_response_error(state, command, result)

      {:push, :ok} ->
        record_push_send(state, command.hook, result.value || [], [
          reply_push(command, {:ok, result.value || []})
        ])

      {:push, :partial_error} ->
        complete_partial_push(state, command, result.reason, result.messages, result.failures)

      {:push, :error} ->
        Transition.new(state, effects: [reply_push(command, {:error, result.reason})])

      {kind, :ok} when kind in [:unavailable, :overloaded, :interaction] ->
        record_background_send(state, command, result.value || command.message)

      {kind, _status} when kind in [:unavailable, :overloaded, :interaction] ->
        Transition.new(state)
    end
  end

  defp clear_auxiliary(state, %{kind: :edit} = command, :telegram_delivery_timeout) do
    if Exiron.Hub.Telegram.TextDelivery.multipart?(command.message),
      do: RecentReplies.forget(state, command.request_id),
      else: RecentReplies.busy(state, command.request_id, false)
  end

  defp clear_auxiliary(state, command, _reason),
    do: RecentReplies.busy(state, command.request_id, false)

  defp normalize_result(%SendCommand{kind: kind, message: message}, result)
       when kind in [:respond, :action, :edit] do
    case SendResult.normalize(result) do
      %SendResult{status: :ok, value: nil} = normalized -> %{normalized | value: message}
      normalized -> normalized
    end
  end

  defp normalize_result(_command, result), do: SendResult.normalize(result)

  defp complete_auxiliary(state, command, message) do
    state = clear_auxiliary(state, command, :ok)

    state =
      if command.kind == :edit do
        state
        |> RecentReplies.remember(command.request_id, command.hook, message)
        |> Runtime.record_event("outgoing", "telegram", command.hook, message, "edit")
      else
        state
      end

    Transition.new(state, effects: [Effect.reply(command.from, :ok), Effect.broadcast_status()])
  end

  defp update_receipt(message) do
    receipt = %{ok: true, final: false, message_id: message.message_id}

    if length(message.text_message_ids) > 1,
      do: Map.put(receipt, :message_ids, message.text_message_ids),
      else: receipt
  end

  defp complete_response(state, %SendCommand{message: %{final?: false}} = command, sent_message) do
    cond do
      not is_integer(sent_message.message_id) or sent_message.message_id <= 0 ->
        terminal_response_failure(state, command, :telegram_delivery_timeout)

      not Map.has_key?(state.delivery.pending, command.request_id) ->
        state = RecentReplies.remember(state, command.request_id, command.hook, sent_message)
        Transition.new(state, effects: [Effect.reply(command.from, {:error, :request_not_found})])

      true ->
        pending = state.delivery.pending[command.request_id]

        pending = %{
          pending
          | response_message_id: sent_message.message_id,
            response_reply_to_message_id: sent_message.reply_to_message_id,
            text_message_ids: sent_message.text_message_ids,
            response_bot_token: sent_message.bot_token,
            response_bot_name: sent_message.bot_name,
            inline_keyboard: sent_message.inline_keyboard,
            callback_buttons: sent_message.callback_buttons
        }

        state = put_in(state.delivery.pending[command.request_id], pending)

        state =
          state
          |> PendingRequests.clear_responding(command.request_id)
          |> RecentReplies.remember(command.request_id, command.hook, sent_message)
          |> Runtime.record_event(
            "outgoing",
            "telegram",
            command.hook,
            sent_message,
            "response_update"
          )

        Transition.new(state,
          effects: [
            Effect.reply(
              command.from,
              {:ok, maybe_receipts(update_receipt(sent_message), command, sent_message)}
            ),
            Effect.broadcast_status()
          ]
        )
    end
  end

  defp complete_response(state, %SendCommand{} = command, sent_message) do
    next_state =
      state
      |> RecentReplies.remember(command.request_id, command.hook, sent_message)
      |> DeliveryHealth.response_completed(command.hook, command.pending)
      |> PendingRequests.delete(command.request_id)
      |> Runtime.record_event("outgoing", "telegram", command.hook, sent_message, "response")

    Transition.new(next_state,
      effects: [
        Effect.cancel_timer(timer(command.pending)),
        Effect.reply(command.from, response_receipt(command, sent_message)),
        Effect.broadcast_status()
      ]
    )
  end

  defp complete_response_error(state, command, %SendResult{reason: :telegram_delivery_timeout}) do
    terminal_response_failure(state, command, :telegram_delivery_timeout)
  end

  defp complete_response_error(
         state,
         %SendCommand{} = command,
         %SendResult{reason: %ExGram.Error{code: code}}
       )
       when code in @telegram_auth_failure_codes do
    terminal_response_failure(state, command, telegram_delivery_error(code))
  end

  defp complete_response_error(state, %SendCommand{} = command, %SendResult{} = result) do
    reason = result.reason
    response = result.original || {:error, reason}

    next_state =
      state
      |> PendingRequests.clear_responding(command.request_id)
      |> Runtime.record_send_failure(
        "reply",
        command.hook,
        Telegram.annotate_message(state.telegram, command.message),
        response
      )

    Transition.new(next_state,
      effects: [Effect.reply(command.from, response), Effect.broadcast_status()]
    )
  end

  defp terminal_response_failure(state, %SendCommand{} = command, reason) do
    next_state =
      state
      |> PendingRequests.delete(command.request_id)
      |> Runtime.record_send_failure(
        "reply",
        command.hook,
        Telegram.annotate_message(state.telegram, command.message),
        reason
      )
      |> Runtime.record_event(
        "outgoing",
        "telegram",
        command.hook,
        command.message,
        "response_failed"
      )

    Transition.new(next_state,
      effects: [
        Effect.cancel_timer(timer(command.pending)),
        Effect.reply(command.from, {:error, reason}),
        Effect.broadcast_status()
      ]
    )
  end

  defp complete_partial_push(state, %SendCommand{} = command, reason, messages, failures) do
    reply = reply_push(command, {:partial_error, reason, messages})

    state
    |> record_push_failures(command.hook, failures)
    |> record_push_send(command.hook, messages, [reply])
  end

  defp record_background_send(state, %SendCommand{kind: kind, hook: hook}, message) do
    state =
      if kind == :interaction,
        do: Exiron.Hub.InlineKeyboard.remember(state, hook, message),
        else: state

    state = Exiron.Hub.GuidedCommands.remember(state, message)

    next_state =
      Runtime.record_event(state, "outgoing", "telegram", hook, message, Atom.to_string(kind))

    Transition.new(next_state, effects: [Effect.broadcast_status()])
  end

  defp record_push_send(state, hook, messages, effects) do
    state = Enum.reduce(messages, state, &Exiron.Hub.InlineKeyboard.remember(&2, hook, &1))
    next_state = Runtime.record_push_events(state, hook, messages)
    Transition.new(next_state, effects: effects ++ [Effect.broadcast_status()])
  end

  defp record_push_failures(state, hook, failures) do
    Enum.reduce(failures, state, fn {message, reason}, acc ->
      Runtime.record_send_failure(
        acc,
        "push",
        hook,
        Telegram.annotate_message(acc.telegram, message),
        reason
      )
    end)
  end

  defp maybe_receipts(payload, %{return_receipts?: true}, message),
    do: Map.put(payload, :receipts, Exiron.Hub.DeliveryReceipt.from_messages([message]))

  defp maybe_receipts(payload, _command, _message), do: payload

  defp response_receipt(%{return_receipts?: true}, message),
    do: {:ok, %{ok: true, receipts: Exiron.Hub.DeliveryReceipt.from_messages([message])}}

  defp response_receipt(_command, _message), do: :ok

  defp reply_push(%{return_receipts?: true, from: from}, {:ok, messages}) do
    Effect.reply(
      from,
      {:ok,
       %{sent: length(messages), receipts: Exiron.Hub.DeliveryReceipt.from_messages(messages)}}
    )
  end

  defp reply_push(%{from: from}, {:ok, messages}), do: Effect.reply(from, {:ok, length(messages)})

  defp reply_push(%{from: from}, {:partial_error, reason, _messages}),
    do: Effect.reply(from, {:error, push_error_reason(reason)})

  defp reply_push(%{from: from}, {:error, reason}),
    do: Effect.reply(from, {:error, push_error_reason(reason)})

  defp push_error_reason(%ExGram.Error{code: code}) when code in @telegram_auth_failure_codes,
    do: telegram_delivery_error(code)

  defp push_error_reason(reason), do: reason

  defp telegram_delivery_error(401), do: :telegram_bot_unauthorized
  defp telegram_delivery_error(403), do: :telegram_bot_forbidden

  defp timer(%{timer: timer}), do: timer
  defp timer(_pending), do: nil
end
