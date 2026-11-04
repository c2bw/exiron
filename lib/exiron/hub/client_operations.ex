defmodule Exiron.Hub.ClientOperations do
  @moduledoc false

  alias Exiron.Hub.{
    AuthenticatedHook,
    ClientSessions,
    Effect,
    Message,
    PendingRequests,
    MessageMetadata,
    MediaAlbum,
    RecentReplies,
    Push,
    Router,
    SendCommand,
    SendTasks,
    Status,
    Transition
  }

  alias Exiron.Hub.Telegram
  alias Exiron.Secret

  def status(state, token, version) do
    with {:ok, hook} <- authorize(state, token) do
      Transition.reply(state, {:ok, Status.snapshot_for_hook(state, version, hook)})
    else
      error -> Transition.reply(state, error)
    end
  end

  def authenticate(state, token, version) do
    with {:ok, hook} <- authorize(state, token) do
      Transition.reply(state, {:ok, %{hook: hook, server_version: version, auth_response: "OK"}})
    else
      error -> Transition.reply(state, error)
    end
  end

  def poll(state, token, opts) do
    perform_poll(state, token, opts, &ClientSessions.poll/3)
  end

  def poll_delivery(state, token, opts) do
    perform_poll(state, token, opts, &ClientSessions.poll_delivery/3)
  end

  defp perform_poll(state, token, opts, poller) do
    transition =
      with {:ok, hook} <- authorize(state, token),
           {:ok, payload, next_state} <- poller.(state, hook, opts) do
        Transition.reply(next_state, {:ok, payload})
      else
        error -> Transition.reply(state, error)
      end

    maybe_broadcast_poll(transition, state)
  end

  def retire(state, token, client_id, delivery_id) do
    with {:ok, hook} <- authorize(state, token),
         {:ok, state} <- Exiron.Hub.ClientRetirement.retire(state, hook, client_id, delivery_id) do
      Transition.new(state, reply: {:ok, %{ok: true}}, effects: [Effect.broadcast_status()])
    else
      error -> Transition.reply(state, error)
    end
  end

  def connect_socket(state, token, opts, version) do
    transition =
      with {:ok, hook} <- authorize(state, token),
           {:ok, connected, state} <- ClientSessions.connect_socket(state, hook, opts) do
        Transition.reply(state, {:ok, Map.put(connected, :server_version, version)})
      else
        error -> Transition.reply(state, error)
      end

    maybe_broadcast_success(transition)
  end

  def disconnect_socket(state, hook, client_id, pid) do
    state
    |> ClientSessions.disconnect_socket(hook, client_id, pid)
    |> Transition.new(reply: :ok, effects: [Effect.broadcast_status()])
  end

  def delivery_diagnostics(state, token, id) do
    with {:ok, hook} <- authorize(state, token) do
      Transition.reply(state, Exiron.Hub.DeliveryDiagnostics.lookup(state, hook, id))
    else
      error -> Transition.reply(state, error)
    end
  end

  def renew_lease(state, token, client_id, batch) do
    with {:ok, hook} <- authorize(state, token),
         {:ok, payload, state} <- Exiron.Hub.ClientLeases.renew(state, hook, client_id, batch) do
      Transition.reply(state, {:ok, payload})
    else
      error -> Transition.reply(state, error)
    end
  end

  def client_runtime_report(state, token, payload) do
    with {:ok, hook} <- authorize(state, token) do
      Exiron.Hub.ClientRuntimeReports.record(state, hook, payload)
    else
      error -> Transition.reply(state, error)
    end
  end

  def handler_report(state, token, payload) do
    with {:ok, hook} <- authorize(state, token) do
      Exiron.Hub.HandlerReports.record(state, hook, payload)
    else
      error -> Transition.reply(state, error)
    end
  end

  def request_state(state, token, id) do
    with {:ok, hook} <- authorize(state, token) do
      Transition.reply(state, Exiron.Hub.RequestControl.snapshot(state, hook, id))
    else
      error -> Transition.reply(state, error)
    end
  end

  def cancel(state, token, id) do
    with {:ok, hook} <- authorize(state, token),
         true <- is_binary(id) and byte_size(id) in 1..128 do
      Exiron.Hub.RequestCancellation.cancel(state, id, hook)
    else
      false -> Transition.reply(state, {:error, :invalid_payload})
      error -> Transition.reply(state, error)
    end
  end

  def respond(state, from, token, request_id, datatype, data, opts) do
    with {:ok, hook} <- authorize(state, token) do
      operation =
        {:respond, request_id, datatype, data, Exiron.Hub.Idempotency.fingerprint_opts(opts)}

      Exiron.Hub.Idempotency.run(
        state,
        hook,
        opts[:idempotency_key],
        operation,
        from,
        &respond_once(&1, from, hook, request_id, datatype, data, opts)
      )
    else
      error -> Transition.reply(state, error)
    end
  end

  defp respond_once(state, from, hook, request_id, datatype, data, opts) do
    with :ok <- validate_payload(datatype, data),
         :ok <- MessageMetadata.validate(datatype, data, opts),
         {:ok, pending} <- PendingRequests.take(state, request_id, hook),
         :ok <- reply_context(pending, opts),
         :ok <- response_mode(pending, datatype, data, opts),
         true <-
           not Keyword.get(opts, :edit_origin, false) or
             (datatype in ["text", "keyboard"] and
                is_integer(Map.get(pending, :callback_message_id))),
         {:ok, state} <-
           SendTasks.admit(state, hook, Exiron.Hub.SendBudget.payload_bytes(data, opts)) do
      start_response(state, from, request_id, pending, hook, datatype, data, opts)
    else
      false -> Transition.reply(state, {:error, :invalid_payload})
      {:error, reason, state} -> capacity_rejected(state, reason, request_id)
      error -> Transition.reply(state, error)
    end
  end

  def push(state, from, token, datatype, data, chat_id, opts) do
    with {:ok, hook} <- authorize(state, token) do
      operation = {:push, chat_id, datatype, data, Exiron.Hub.Idempotency.fingerprint_opts(opts)}

      Exiron.Hub.Idempotency.run(
        state,
        hook,
        opts[:idempotency_key],
        operation,
        from,
        &push_once(&1, from, hook, datatype, data, chat_id, opts)
      )
    else
      error -> Transition.reply(state, error)
    end
  end

  defp push_once(state, from, hook, datatype, data, chat_id, opts) do
    with :ok <- Exiron.Hub.Drain.admit(state),
         :ok <- validate_payload(datatype, data),
         :ok <- MessageMetadata.validate(datatype, data, opts),
         :ok <- topic_target(chat_id, opts),
         :ok <- reject_reply_context(opts),
         true <- datatype != "keyboard",
         {:ok, state} <-
           SendTasks.admit(state, hook, Exiron.Hub.SendBudget.payload_bytes(data, opts)) do
      start_push(state, from, hook, datatype, data, chat_id, opts)
    else
      false -> Transition.reply(state, {:error, :invalid_payload})
      {:error, reason, state} -> capacity_rejected(state, reason)
      error -> Transition.reply(state, error)
    end
  end

  def action(state, from, token, request_id, action, opts \\ []) do
    with {:ok, hook} <- authorize(state, token),
         true <- is_nil(opts[:idempotency_key]),
         true <- action in MessageMetadata.actions(),
         {:ok, pending} <- PendingRequests.take(state, request_id, hook),
         {:ok, state} <-
           SendTasks.admit(state, hook, Exiron.Hub.SendBudget.payload_bytes(action, opts)) do
      message = %Message{
        datatype: "action",
        data: action,
        service_id: pending.service_id,
        chat_id: pending.chat_id,
        bot_token: Map.get(pending, :response_bot_token) || pending.bot_token,
        bot_name: Map.get(pending, :response_bot_name) || pending.bot_name,
        message_thread_id: Map.get(pending, :message_thread_id)
      }

      auxiliary_send(
        state,
        from,
        %SendCommand{
          return_receipts?: opts[:delivery_receipts] == true,
          return_diagnostics?: opts[:delivery_diagnostics] == true,
          payload_bytes: Exiron.Hub.SendBudget.payload_bytes(action, opts),
          kind: :action,
          from: from,
          request_id: request_id,
          hook: hook,
          message: message
        },
        state
      )
    else
      false -> Transition.reply(state, {:error, :invalid_payload})
      {:error, reason, state} -> capacity_rejected(state, reason, request_id)
      error -> Transition.reply(state, error)
    end
  end

  def edit(state, from, token, request_id, datatype, data, opts) do
    with {:ok, hook} <- authorize(state, token),
         true <- is_nil(opts[:idempotency_key]),
         :ok <- Exiron.Hub.Drain.admit(state),
         true <-
           datatype == "keyboard" or
             (datatype == "text" and MessageMetadata.valid_stream_text?(data)),
         :ok <- validate_payload(datatype, data),
         :ok <- MessageMetadata.validate(datatype, data, opts),
         :ok <- reject_reply_context(opts),
         {:ok, receipt} <- RecentReplies.take(state, request_id, hook),
         false <- Map.has_key?(state.delivery.pending, request_id),
         {:ok, state} <-
           SendTasks.admit(state, hook, Exiron.Hub.SendBudget.payload_bytes(data, opts)) do
      message =
        Message.outgoing(
          receipt.service_id,
          receipt.chat_id,
          datatype,
          data,
          receipt.bot_token,
          opts
          |> Keyword.put(:bot_name, receipt.bot_name)
          |> Keyword.put(:message_thread_id, receipt.message_thread_id)
          |> Keyword.put(:edit_message_id, receipt.message_id)
          |> Keyword.put(:reply_to_message_id, Map.get(receipt, :reply_to_message_id))
          |> Keyword.put(:text_message_ids, Map.get(receipt, :text_message_ids, []))
          |> Keyword.put_new(:parse_mode, "plain")
        )

      message =
        message
        |> Exiron.Hub.InlineKeyboard.prepare(request_id)
        |> Exiron.Hub.InlineKeyboard.inherit(receipt)

      auxiliary_send(
        RecentReplies.busy(state, request_id, true),
        from,
        %SendCommand{
          return_receipts?: opts[:delivery_receipts] == true,
          return_diagnostics?: opts[:delivery_diagnostics] == true,
          payload_bytes: Exiron.Hub.SendBudget.payload_bytes(data, opts),
          kind: :edit,
          from: from,
          request_id: request_id,
          hook: hook,
          message: message
        },
        state
      )
    else
      true -> Transition.reply(state, {:error, :request_in_flight})
      false -> Transition.reply(state, {:error, :invalid_payload})
      {:error, reason, state} -> capacity_rejected(state, reason, request_id)
      error -> Transition.reply(state, error)
    end
  end

  defp capacity_rejected(state, reason, request_id \\ nil) do
    state =
      Exiron.Hub.RequestTrace.record(state, request_id, :send_capacity_rejected, detail: reason)

    Transition.new(state, reply: {:error, reason}, effects: [Effect.broadcast_status()])
  end

  defp auxiliary_send(state, from, command, failure_state) do
    telegram = state.telegram

    Transition.new(state,
      effects: [
        Effect.start_send(
          from,
          command,
          fn -> Telegram.send_message(telegram, command.message) end,
          failure_state
        )
      ]
    )
  end

  defp response_mode(pending, datatype, data, opts) do
    streaming? =
      not Keyword.get(opts, :final, true) or is_integer(Map.get(pending, :response_message_id))

    if (datatype != "keyboard" or Keyword.get(opts, :edit_origin, false)) and
         (not streaming? or (datatype == "text" and MessageMetadata.valid_stream_text?(data))),
       do: :ok,
       else: {:error, :invalid_payload}
  end

  defp start_response(state, from, request_id, pending, hook, datatype, data, opts) do
    message =
      Message.outgoing(
        pending.service_id,
        pending.chat_id,
        datatype,
        data,
        Map.get(pending, :response_bot_token) || pending.bot_token,
        response_opts(opts, pending)
      )

    context =
      if Keyword.get(opts, :edit_origin, false) and is_nil(Map.get(pending, :response_message_id)),
        do: %{
          inline_keyboard: Map.get(pending, :origin_keyboard),
          callback_buttons: Map.get(pending, :origin_buttons)
        },
        else: pending

    message =
      message
      |> Exiron.Hub.InlineKeyboard.prepare(request_id)
      |> Exiron.Hub.InlineKeyboard.inherit(context)

    state =
      state
      |> PendingRequests.mark_responding(request_id)
      |> Exiron.Hub.RequestTrace.record(request_id, :response_received, status: :sending)

    operation = %{
      SendCommand.respond(from, request_id, pending, hook, message)
      | payload_bytes: Exiron.Hub.SendBudget.payload_bytes(data, opts),
        return_receipts?: opts[:delivery_receipts] == true,
        return_diagnostics?: opts[:delivery_diagnostics] == true
    }

    failure_state = PendingRequests.clear_responding(state, request_id)
    telegram = state.telegram

    Transition.new(
      state,
      effects: [
        Effect.start_send(
          from,
          operation,
          fn -> Telegram.send_message(telegram, message) end,
          failure_state
        )
      ]
    )
  end

  defp topic_target(chat_id, opts) do
    if is_nil(opts[:message_thread_id]) or is_integer(chat_id),
      do: :ok,
      else: {:error, :invalid_chat_id}
  end

  defp start_push(state, from, hook, datatype, data, chat_id, opts) do
    operation = %{
      SendCommand.push(from, hook)
      | payload_bytes: Exiron.Hub.SendBudget.payload_bytes(data, opts),
        return_receipts?: opts[:delivery_receipts] == true,
        return_diagnostics?: opts[:delivery_diagnostics] == true
    }

    router = state.router
    telegram = state.telegram

    Transition.new(
      state,
      effects: [
        Effect.start_send(
          from,
          operation,
          fn -> Push.send(router, telegram, hook, datatype, data, chat_id, opts) end,
          state
        )
      ]
    )
  end

  defp authorize(%{enabled?: false}, _token), do: {:error, :disabled}

  defp authorize(%{router: %Router{} = router}, token) do
    case Secret.reveal(token) do
      %AuthenticatedHook{name: hook} ->
        if Map.has_key?(router.hooks, hook), do: {:ok, hook}, else: {:error, :invalid_token}

      token when is_binary(token) ->
        case Router.hook_for_token(router, token) do
          nil -> {:error, :invalid_token}
          hook -> {:ok, hook}
        end

      _token ->
        {:error, :invalid_token}
    end
  end

  defp authorize(_state, _token), do: {:error, :invalid_token}

  defp validate_payload("keyboard", ""), do: :ok

  defp validate_payload("album", data) when is_binary(data) do
    case MediaAlbum.decode(data) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_payload(datatype, data) when is_binary(datatype) and is_binary(data) do
    cond do
      not Message.valid_type?(datatype) -> {:error, :invalid_datatype}
      datatype == "text" and not String.valid?(data) -> {:error, :invalid_payload}
      true -> :ok
    end
  end

  defp validate_payload(_datatype, _data), do: {:error, :invalid_payload}

  defp reject_reply_context(opts) do
    if Keyword.has_key?(opts, :reply_to_original), do: {:error, :invalid_payload}, else: :ok
  end

  defp reply_context(pending, opts) do
    chosen? = Keyword.has_key?(opts, :reply_to_original)
    enabled? = Keyword.get(opts, :reply_to_original, false)
    started? = is_integer(Map.get(pending, :response_message_id))
    current? = is_integer(Map.get(pending, :response_reply_to_message_id))
    source = Map.get(pending, :original_message_id)

    cond do
      chosen? and Keyword.get(opts, :edit_origin, false) -> {:error, :invalid_payload}
      started? and chosen? and enabled? != current? -> {:error, :invalid_payload}
      enabled? and (not is_integer(source) or source <= 0) -> {:error, :invalid_payload}
      true -> :ok
    end
  end

  defp response_opts(opts, pending) do
    target =
      cond do
        is_integer(Map.get(pending, :response_message_id)) ->
          Map.get(pending, :response_reply_to_message_id)

        Keyword.get(opts, :reply_to_original, false) ->
          Map.get(pending, :original_message_id)

        true ->
          nil
      end

    opts =
      opts
      |> Keyword.put(:reply_to_message_id, target)
      |> Keyword.put(:message_thread_id, Map.get(pending, :message_thread_id))

    name = Map.get(pending, :response_bot_name) || Map.get(pending, :bot_name)
    opts = if is_binary(name) and name != "", do: Keyword.put(opts, :bot_name, name), else: opts

    edit_id =
      Map.get(pending, :response_message_id) ||
        if(Keyword.get(opts, :edit_origin, false), do: Map.get(pending, :callback_message_id))

    ids =
      if Keyword.get(opts, :edit_origin, false) and is_nil(Map.get(pending, :response_message_id)),
        do: Map.get(pending, :origin_text_ids, []),
        else: Map.get(pending, :text_message_ids, [])

    opts = opts |> Keyword.put(:edit_message_id, edit_id) |> Keyword.put(:text_message_ids, ids)

    if not Keyword.get(opts, :final, true) or is_integer(Map.get(pending, :response_message_id)),
      do: Keyword.put_new(opts, :parse_mode, "plain"),
      else: opts
  end

  defp maybe_broadcast_success(%Transition{reply: {:ok, _payload}} = transition) do
    Transition.effect(transition, Effect.broadcast_status())
  end

  defp maybe_broadcast_success(transition), do: transition

  defp maybe_broadcast_poll(
         %Transition{next_state: next_state, reply: {:ok, _payload}} = transition,
         previous_state
       ) do
    if Status.client_poll_changed?(previous_state, next_state) or
         previous_state.activity.trace_revision != next_state.activity.trace_revision do
      Transition.effect(transition, Effect.broadcast_status())
    else
      transition
    end
  end

  defp maybe_broadcast_poll(transition, _previous_state), do: transition
end
