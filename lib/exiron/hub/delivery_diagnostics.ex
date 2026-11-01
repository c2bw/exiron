defmodule Exiron.Hub.DeliveryDiagnostics do
  @moduledoc false
  alias Exiron.Hub.{Identifier, RequestTrace}
  @limit 500
  @parts 128

  def new(command) do
    %{
      id: Identifier.new(),
      request_id: command.request_id,
      operation: Atom.to_string(command.kind),
      hook: command.hook,
      sequence: System.unique_integer([:positive, :monotonic]),
      outcome: "sending",
      attempts: 0,
      planned_parts: 0,
      parts: %{},
      current: nil,
      confirmed: 0,
      rejected: 0,
      unknown: 0,
      in_flight: 0,
      last_error: nil,
      retry_available: false,
      uncertain?: false
    }
  end

  def group(message) do
    if Process.get(:exiron_trace_send) do
      group = Process.get(:exiron_delivery_group, 0) + 1
      Process.put(:exiron_delivery_group, group)
      %{message | delivery_group: group}
    else
      message
    end
  end

  def metadata(message, index \\ nil) do
    %{
      group: message.delivery_group,
      chat_id: message.chat_id,
      bot_name: message.bot_name,
      index: index || message.delivery_index,
      operation:
        cond do
          message.datatype == "delete" -> "delete"
          message.datatype == "action" -> "action"
          is_integer(message.edit_message_id) -> "edit"
          true -> "send"
        end,
      message_id: message.edit_message_id
    }
  end

  def plan(message, count \\ 1, previous_ids \\ []) do
    entries =
      for index <- 1..count do
        metadata(
          %{
            message
            | edit_message_id:
                if(previous_ids == [] and index == 1,
                  do: message.edit_message_id,
                  else: Enum.at(previous_ids, index - 1)
                )
          },
          index
        )
      end

    removals =
      previous_ids
      |> Enum.drop(count)
      |> Enum.with_index(count + 1)
      |> Enum.map(fn {id, index} ->
        metadata(%{message | datatype: "delete", edit_message_id: id}, index)
      end)

    report({:plan, entries ++ removals})
  end

  def report(phase) do
    case Process.get(:exiron_trace_send) do
      {owner, ref, _} -> GenServer.call(owner, {:send_attempt, ref, phase}, :infinity)
      _ -> :ok
    end
  end

  def planned(diagnostic, entries) do
    Enum.reduce(entries, diagnostic, fn meta, diagnostic ->
      part = part(meta, diagnostic.planned_parts + 1)
      diagnostic = %{diagnostic | planned_parts: diagnostic.planned_parts + 1}
      put_part(diagnostic, part)
    end)
  end

  def blocked(diagnostic, meta, error) do
    part = Map.get(diagnostic.parts, key(meta)) || part(meta, diagnostic.planned_parts)
    diagnostic = transition_count(diagnostic, part.status, "rejected")
    part = %{part | status: "rejected", error: error}
    put_part(%{diagnostic | current: part, last_error: error}, part)
  end

  def begin_attempt(diagnostic, meta) do
    key = key(meta)

    part =
      Map.get(diagnostic.parts, key) ||
        if(diagnostic.current && diagnostic.current.key == key, do: diagnostic.current) ||
        part(meta, diagnostic.planned_parts)

    diagnostic = transition_count(diagnostic, part.status, "in_flight")

    part =
      Map.merge(part, meta) |> Map.put(:status, "in_flight") |> Map.update!(:attempts, &(&1 + 1))

    diagnostic = %{diagnostic | current: part, attempts: diagnostic.attempts + 1}
    put_part(diagnostic, part)
  end

  def finish_attempt(%{current: nil} = diagnostic, _, _, _), do: diagnostic

  def finish_attempt(diagnostic, status, ids, error) do
    status = %{ok: "confirmed", rejected: "rejected", unknown: "unknown"}[status]
    old = diagnostic.current
    diagnostic = transition_count(diagnostic, old.status, status)

    part = %{
      old
      | status: status,
        message_id: List.first(ids) || old.message_id,
        message_ids: ids,
        error: error || old.error
    }

    diagnostic = %{
      diagnostic
      | current: part,
        last_error: error || diagnostic.last_error,
        uncertain?: diagnostic.uncertain? or status == "unknown"
    }

    put_part(diagnostic, part)
  end

  def finish(diagnostic, outcome, reason, available) do
    diagnostic =
      if diagnostic.current && diagnostic.current.status == "in_flight",
        do: finish_attempt(diagnostic, :unknown, [], error(reason)),
        else: diagnostic

    %{
      diagnostic
      | outcome: outcome,
        retry_available: available,
        last_error:
          diagnostic.last_error ||
            if(outcome not in ["succeeded", "cancelled", "expired"], do: error(reason))
    }
  end

  def snapshot(diagnostic) do
    status =
      cond do
        diagnostic.unknown > 0 or diagnostic.in_flight > 0 or diagnostic.uncertain? -> "unknown"
        diagnostic.confirmed > 0 and diagnostic.outcome == "succeeded" -> "confirmed"
        diagnostic.confirmed > 0 -> "partial"
        true -> "not_started"
      end

    {action, safe} =
      cond do
        diagnostic.outcome == "sending" ->
          {"wait", false}

        diagnostic.outcome == "succeeded" ->
          {"none", false}

        status in ["partial", "unknown"] ->
          {"inspect_chat", false}

        not diagnostic.retry_available ->
          {"request_closed", false}

        diagnostic.last_error &&
            diagnostic.last_error.category in ["rate_limited", "delivery_timeout"] ->
          {"retry_request", true}

        true ->
          {"fix_request", true}
      end

    %{
      id: diagnostic.id,
      request_id: diagnostic.request_id,
      operation: diagnostic.operation,
      outcome: diagnostic.outcome,
      delivery_status: status,
      attempts: diagnostic.attempts,
      planned_parts: diagnostic.planned_parts,
      confirmed_parts: diagnostic.confirmed,
      rejected_parts: diagnostic.rejected,
      unknown_parts: diagnostic.unknown,
      in_flight_parts: diagnostic.in_flight,
      unattempted_parts:
        max(
          diagnostic.planned_parts - diagnostic.confirmed - diagnostic.rejected -
            diagnostic.unknown - diagnostic.in_flight,
          0
        ),
      omitted_parts: max(diagnostic.planned_parts - map_size(diagnostic.parts), 0),
      retry_available: diagnostic.retry_available,
      retry_safe: safe,
      retry_action: action,
      last_error: diagnostic.last_error,
      parts:
        diagnostic.parts
        |> Map.values()
        |> Enum.sort_by(& &1.ordinal)
        |> Enum.map(&Map.drop(&1, [:key, :group]))
    }
  end

  def retain(state, diagnostic) do
    order =
      [diagnostic.id | List.delete(state.delivery.diagnostic_order, diagnostic.id)]
      |> Enum.take(@limit)

    records = state.delivery.diagnostics |> Map.put(diagnostic.id, diagnostic) |> Map.take(order)

    %{state | delivery: %{state.delivery | diagnostics: records, diagnostic_order: order}}
    |> trace(diagnostic)
  end

  def trace(state, diagnostic),
    do: RequestTrace.delivery(state, diagnostic.request_id, snapshot(diagnostic))

  def close_request(state, id, hook, outcome) do
    diagnostic =
      state.delivery.diagnostics
      |> Map.values()
      |> Enum.filter(&(&1.request_id == id and &1.hook == hook))
      |> Enum.max_by(& &1.sequence, fn -> nil end)

    if diagnostic, do: retain(state, finish(diagnostic, outcome, nil, false)), else: state
  end

  def lookup(state, hook, id) when is_binary(id) do
    active =
      Enum.flat_map(state.delivery.sends, fn {_, task} ->
        if task.diagnostic, do: [task.diagnostic], else: []
      end)

    matching =
      (active ++ Map.values(state.delivery.diagnostics))
      |> Enum.filter(&(&1.id == id or &1.request_id == id))

    case matching
         |> Enum.filter(&(&1.hook == hook))
         |> Enum.max_by(& &1.sequence, fn -> nil end) do
      nil ->
        if matching == [],
          do: {:error, :delivery_not_found},
          else: {:error, :request_not_assigned}

      diagnostic ->
        {:ok, snapshot(diagnostic)}
    end
  end

  def lookup(_, _, _), do: {:error, :delivery_not_found}

  def finalize(transition, task, outcome, reason, previous_failures) do
    returned_error =
      Enum.find_value(transition.effects, fn
        %{kind: :reply, payload: {_, {:error, reason}}} -> {:error, reason}
        _ -> nil
      end)

    {outcome, reason} =
      case {outcome, returned_error} do
        {"succeeded", {:error, error}} -> {"failed", error}
        {_, {:error, error}} -> {outcome, reason || error}
        _ -> {outcome, reason}
      end

    available =
      case task.command.kind do
        :push -> true
        :edit -> Map.has_key?(transition.next_state.delivery.replies, task.command.request_id)
        _ -> Map.has_key?(transition.next_state.delivery.pending, task.command.request_id)
      end

    diagnostic = finish(task.diagnostic || new(task.command), outcome, reason, available)
    state = retain(transition.next_state, diagnostic)
    # Failure history and traces refer to the same bounded, sanitized snapshot.
    failures =
      Enum.map(state.activity.send_failures, fn failure ->
        if not MapSet.member?(previous_failures, failure.id) and
             failure.hook == task.command.hook and not Map.has_key?(failure, :delivery) do
          Map.put(failure, :delivery, snapshot(diagnostic))
        else
          failure
        end
      end)

    state = %{state | activity: %{state.activity | send_failures: failures}}

    %{
      transition
      | next_state: state,
        effects: Enum.map(transition.effects, &enrich_effect(&1, task.command, diagnostic))
    }
  end

  def enrich_effect(
        %{kind: :reply, payload: {from, {:error, reason}}} = effect,
        %{return_diagnostics?: true},
        diagnostic
      ),
      do: %{effect | payload: {from, {:error, {:delivery_error, reason, snapshot(diagnostic)}}}}

  def enrich_effect(effect, _, _), do: effect

  def error(%ExGram.Error{code: code}) when is_integer(code) do
    {category, message} =
      case code do
        400 ->
          {"bad_request", "Telegram rejected the payload or message operation."}

        401 ->
          {"unauthorized", "Telegram rejected the bot credentials."}

        403 ->
          {"forbidden", "Telegram denied access to this chat or operation."}

        429 ->
          {"rate_limited", "Telegram requires a delay before another attempt."}

        n when n >= 500 ->
          {"telegram_unavailable", "Telegram returned a server error; delivery may be uncertain."}

        _ ->
          {"telegram_error", "Telegram rejected this operation."}
      end

    %{category: category, message: message, code: code, retry_after_ms: nil}
  end

  def error({:error, reason}), do: error(reason)

  def error(:telegram_bot_not_configured),
    do: %{
      category: "bot_not_configured",
      message: "No configured bot can send to this chat.",
      code: nil,
      retry_after_ms: nil
    }

  def error(:telegram_delivery_timeout),
    do: %{
      category: "delivery_timeout",
      message: "Delivery stopped at its deadline or after a partial result.",
      code: nil,
      retry_after_ms: nil
    }

  def error(:invalid_payload),
    do: %{
      category: "invalid_payload",
      message: "The payload cannot be delivered; check its formatting and limits.",
      code: nil,
      retry_after_ms: nil
    }

  def error(_),
    do: %{
      category: "transport_error",
      message: "The delivery result is uncertain.",
      code: nil,
      retry_after_ms: nil
    }

  def telegram_error(%ExGram.Error{} = reason) do
    error = error(reason)
    Map.put(error, :retry_after_ms, Exiron.Hub.Telegram.SendCoordinator.retry_delay(reason))
  end

  def telegram_error(reason), do: error(reason)

  defp part(meta, ordinal),
    do:
      Map.merge(meta, %{
        key: key(meta),
        ordinal: ordinal,
        id: "part-#{ordinal}",
        status: "queued",
        attempts: 0,
        message_ids: [],
        error: nil
      })

  defp key(meta), do: {Map.get(meta, :group, 0), meta.chat_id, meta.index, meta.operation}

  defp put_part(diagnostic, part) do
    if Map.has_key?(diagnostic.parts, part.key) or map_size(diagnostic.parts) < @parts,
      do: %{diagnostic | parts: Map.put(diagnostic.parts, part.key, part)},
      else: diagnostic
  end

  defp transition_count(diagnostic, previous, next) do
    diagnostic |> change_count(previous, -1) |> change_count(next, 1)
  end

  defp change_count(diagnostic, status, delta) do
    case status do
      "confirmed" -> Map.update!(diagnostic, :confirmed, &(&1 + delta))
      "rejected" -> Map.update!(diagnostic, :rejected, &(&1 + delta))
      "unknown" -> Map.update!(diagnostic, :unknown, &(&1 + delta))
      "in_flight" -> Map.update!(diagnostic, :in_flight, &(&1 + delta))
      _ -> diagnostic
    end
  end
end
