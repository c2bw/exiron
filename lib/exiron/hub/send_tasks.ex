defmodule Exiron.Hub.SendTasks do
  @moduledoc false

  alias Exiron.Hub.{
    DeliveryHealth,
    Effect,
    SendCommand,
    SendResult,
    SendResults,
    SendTask,
    Telegram,
    Transition
  }

  alias Exiron.Telemetry

  # Admission happens only after the bot's coordinator grants a slot. This
  # serializes cancellation with permission to start each HTTP attempt.
  def telegram_attempt(message, fun) do
    case Process.get(:exiron_trace_send) do
      {owner, ref, _id} ->
        case GenServer.call(
               owner,
               {:send_attempt, ref,
                {:begin, message.datatype, Exiron.Hub.DeliveryDiagnostics.metadata(message)}},
               :infinity
             ) do
          :ok ->
            result =
              try do
                fun.()
              catch
                kind, reason ->
                  GenServer.call(
                    owner,
                    {:send_attempt, ref,
                     {:finished, :unknown, [], nil,
                      Exiron.Hub.DeliveryDiagnostics.error(:exception)}},
                    :infinity
                  )

                  :erlang.raise(kind, reason, __STACKTRACE__)
              end

            {status, ids} = attempt_result(result)

            removed =
              if status == :ok and message.datatype == "delete", do: message.edit_message_id

            GenServer.call(
              owner,
              {:send_attempt, ref, {:finished, status, ids, removed, diagnostic_error(result)}},
              :infinity
            )

            result

          error ->
            error
        end

      _ ->
        fun.()
    end
  end

  def attempt_progress(state, ref, pid, phase) do
    with %{pid: ^pid, command: %{request_id: id}} = task <- Map.get(state.delivery.sends, ref),
         pending = Map.get(state.delivery.pending, id),
         true <-
           not is_nil(pending) or
             task.command.kind in [:edit, :push, :unavailable, :overloaded, :interaction] do
      case phase do
        {:plan, entries} ->
          task = %{
            task
            | diagnostic: Exiron.Hub.DeliveryDiagnostics.planned(task.diagnostic, entries)
          }

          {:ok,
           state
           |> put_in([Access.key!(:delivery), Access.key!(:sends), ref], task)
           |> Exiron.Hub.DeliveryDiagnostics.trace(task.diagnostic)}

        {:blocked, meta, error} ->
          task = %{
            task
            | diagnostic: Exiron.Hub.DeliveryDiagnostics.blocked(task.diagnostic, meta, error)
          }

          state = put_in(state.delivery.sends[ref], task)
          {:ok, Exiron.Hub.DeliveryDiagnostics.trace(state, task.diagnostic)}

        {:begin, type, meta} ->
          task = %{
            task
            | attempt_in_flight?: type != "action",
              diagnostic: Exiron.Hub.DeliveryDiagnostics.begin_attempt(task.diagnostic, meta)
          }

          {:ok,
           state
           |> put_in([Access.key!(:delivery), Access.key!(:sends), ref], task)
           |> Exiron.Hub.DeliveryDiagnostics.trace(task.diagnostic)}

        {:finished, status, ids, removed, error} ->
          pending =
            if task.command.kind == :action or is_nil(pending) do
              pending
            else
              known =
                (Map.get(pending, :delivery_message_ids, []) ++ ids)
                |> Enum.uniq()
                |> Enum.reject(&(&1 == removed))

              pending
              |> Map.put(:delivery_message_ids, known)
              |> Map.put(:delivered?, Map.get(pending, :delivered?, false) or status == :ok)
              |> Map.put(
                :delivery_unknown?,
                Map.get(pending, :delivery_unknown?, false) or status == :unknown
              )
            end

          state = if is_nil(pending), do: state, else: put_in(state.delivery.pending[id], pending)

          task = %{
            task
            | attempt_in_flight?: false,
              diagnostic:
                Exiron.Hub.DeliveryDiagnostics.finish_attempt(task.diagnostic, status, ids, error)
          }

          state = put_in(state.delivery.sends[ref], task)
          {:ok, Exiron.Hub.DeliveryDiagnostics.trace(state, task.diagnostic)}
      end
    else
      _ -> {{:error, :request_not_found}, state}
    end
  end

  defp diagnostic_error({:error, reason}),
    do: Exiron.Hub.DeliveryDiagnostics.telegram_error(reason)

  defp diagnostic_error(_), do: nil

  defp attempt_result(:ok), do: {:ok, []}

  defp attempt_result({:ok, value}) do
    ids =
      value
      |> List.wrap()
      |> Enum.flat_map(fn
        %{message_id: id} when is_integer(id) and id > 0 -> [id]
        _ -> []
      end)

    {:ok, ids}
  end

  defp attempt_result({:error, %ExGram.Error{code: code}})
       when is_integer(code) and code in 400..499, do: {:rejected, []}

  defp attempt_result(_), do: {:unknown, []}

  def in_flight_for_hook(state, hook) do
    Enum.count(state.delivery.sends, fn
      {_ref, %{command: %{hook: ^hook}}} -> true
      _ -> false
    end)
  end

  def hook_limit(state),
    do: min(state.settings.max_in_flight_sends_per_hook, state.settings.max_in_flight_sends)

  def ensure_capacity(state, hook, bytes \\ 0) do
    cond do
      map_size(state.delivery.sends) >= state.settings.max_in_flight_sends ->
        {:error, :send_queue_full}

      in_flight_for_hook(state, hook) >= hook_limit(state) ->
        {:error, :hook_send_queue_full}

      Exiron.Hub.SendBudget.usage(state) + bytes > state.settings.max_in_flight_send_bytes ->
        {:error, :send_queue_full}

      Exiron.Hub.SendBudget.usage(state, hook) + bytes > Exiron.Hub.SendBudget.hook_limit(state) ->
        {:error, :hook_send_queue_full}

      true ->
        :ok
    end
  end

  def admit(state, hook, bytes \\ 0) do
    case ensure_capacity(state, hook, bytes) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, capacity_rejected(state, hook, bytes)}
    end
  end

  def capacity_rejected(state, hook, bytes) do
    state = DeliveryHealth.send_capacity_rejected(state, hook)

    if Exiron.Hub.SendBudget.exceeded?(state, hook, bytes),
      do: Exiron.Hub.SendBudget.reject(state, hook),
      else: state
  end

  def start(state, from, command, fun) do
    owner = self()
    ref = make_ref()

    case start_child(fn ->
           Process.put(:exiron_trace_send, {owner, ref, command.request_id})
           send(owner, {:send_complete, ref, safe_send_result(fun)})
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        timer = Process.send_after(owner, {:send_timeout, ref}, state.settings.send_timeout)

        send_state = %{
          SendTask.new(from, command, pid, monitor, timer)
          | diagnostic: Exiron.Hub.DeliveryDiagnostics.new(command)
        }

        state =
          Exiron.Hub.RequestTrace.record(
            state,
            command.request_id,
            case command.kind do
              :action -> :chat_action_started
              :edit -> :edit_started
              _ -> :send_started
            end,
            if(command.kind == :respond, do: [status: :sending], else: [])
          )

        {:ok, put_in(state.delivery.sends[ref], send_state)}

      {:error, _reason} ->
        {:error, :send_unavailable}
    end
  end

  def finish(state, ref, result),
    do: with_send(state, ref, &complete(&1, &2, result))

  def expire(state, ref), do: with_send(state, ref, &timeout/2)

  def task_down(state, monitor, pid, reason) do
    case find_send(state.delivery.sends, monitor, pid) do
      nil ->
        {:unchanged, state}

      {_ref, _send_task} when reason == :normal ->
        {:unchanged, state}

      {ref, _send_task} ->
        case pop_send(state, ref) do
          {nil, state} ->
            {:unchanged, state}

          {send_task, state} ->
            {:failed, complete(state, send_task, SendResult.error({:exit, reason}))}
        end
    end
  end

  def timeout(state, %SendTask{command: command, pid: pid} = task) do
    unknown? =
      is_nil(task.diagnostic) or task.diagnostic.in_flight > 0 or task.diagnostic.unknown > 0 or
        task.diagnostic.uncertain?

    previous_failures = MapSet.new(state.activity.send_failures, & &1.id)

    state
    |> Exiron.Hub.RequestTrace.record(
      command.request_id,
      if(command.kind == :respond and unknown?,
        do: :telegram_delivery_unknown,
        else: :auxiliary_send_timeout
      ),
      if(command.kind == :respond,
        do: [status: if(unknown?, do: :delivery_unknown, else: :failed)],
        else: []
      )
    )
    |> record_outcome(task, :timeout)
    |> SendResults.timeout(command)
    |> Exiron.Hub.DeliveryDiagnostics.finalize(
      task,
      "timed_out",
      :telegram_delivery_timeout,
      previous_failures
    )
    |> Transition.prepend_effect(Effect.terminate_task(pid))
    |> publish_health()
  end

  def start_background_sends(state, sends) do
    telegram = state.telegram

    effects =
      Enum.map(sends, fn %SendCommand{kind: kind} = command
                         when kind in [:unavailable, :overloaded, :interaction] ->
        message = command.message

        Effect.start_send(
          nil,
          command,
          fn -> Telegram.send_message(telegram, message) end,
          state
        )
      end)

    Transition.new(state, effects: effects)
  end

  def complete(state, %SendTask{command: command, timer: timer} = task, result) do
    state =
      if task.attempt_in_flight? and Map.has_key?(state.delivery.pending, command.request_id) do
        update_in(
          state.delivery.pending[command.request_id],
          &Map.put(&1, :delivery_unknown?, true)
        )
      else
        state
      end

    previous_failures = MapSet.new(state.activity.send_failures, & &1.id)
    normalized = SendResult.normalize(result)
    transition = SendResults.complete(state, command, result)

    reply_failed? =
      Enum.any?(transition.effects, &match?(%{kind: :reply, payload: {_, {:error, _}}}, &1))

    outcome = if normalized.status == :ok and reply_failed?, do: :error, else: normalized.status
    transition = %{transition | next_state: record_outcome(transition.next_state, task, outcome)}

    status =
      cond do
        outcome == :ok and command.kind == :respond and not command.message.final? ->
          :awaiting_response

        outcome == :ok ->
          :completed

        Map.has_key?(transition.next_state.delivery.pending, command.request_id) ->
          :send_failed

        true ->
          :failed
      end

    next_state =
      Exiron.Hub.RequestTrace.record(
        transition.next_state,
        command.request_id,
        case {command.kind, outcome} do
          {:action, :ok} -> :chat_action_sent
          {:edit, :ok} -> :reply_edited
          {:respond, :ok} when not command.message.final? -> :telegram_updated
          {_, :ok} -> :telegram_sent
          _ -> :telegram_send_failed
        end,
        if(command.kind == :respond, do: [status: status], else: [])
      )

    %{transition | next_state: next_state}
    |> Exiron.Hub.DeliveryDiagnostics.finalize(
      task,
      if(outcome == :ok, do: "succeeded", else: "failed"),
      normalized.reason,
      previous_failures
    )
    |> Transition.prepend_effect(Effect.cancel_timer(timer))
    |> publish_health()
  end

  defp record_outcome(state, task, outcome) do
    if is_integer(task.started_at) do
      Telemetry.send(
        max(System.monotonic_time() - task.started_at, 0),
        task.command.kind,
        outcome
      )
    end

    if outcome == :ok, do: state, else: DeliveryHealth.send_failed(state, task.command.hook)
  end

  defp publish_health(transition) do
    if Enum.any?(transition.effects, &(&1.kind == :broadcast_status)),
      do: transition,
      else: Transition.effect(transition, Effect.broadcast_status())
  end

  def safe_result(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_send_result(fun), do: fun |> safe_result() |> SendResult.normalize()

  defp start_child(fun) do
    Task.Supervisor.start_child(Exiron.Hub.SendSupervisor, fun, shutdown: :brutal_kill)
  catch
    :exit, reason -> {:error, reason}
  end

  defp pop_send(state, ref) do
    {send_op, sends} = Map.pop(state.delivery.sends, ref)

    if send_op do
      Process.demonitor(send_op.monitor, [:flush])
    end

    {send_op, %{state | delivery: %{state.delivery | sends: sends}}}
  end

  defp with_send(state, ref, fun) do
    case pop_send(state, ref) do
      {nil, state} -> Transition.new(state)
      {send_task, state} -> fun.(state, send_task)
    end
  end

  defp find_send(sends, monitor, pid) do
    Enum.find(sends, fn {_ref, send_op} ->
      send_op.monitor == monitor and send_op.pid == pid
    end)
  end
end
