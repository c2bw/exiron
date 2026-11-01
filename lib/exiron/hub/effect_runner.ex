defmodule Exiron.Hub.EffectRunner do
  @moduledoc false

  alias Exiron.Hub.{
    ClientSessions,
    DeliveryHealth,
    Effect,
    SendTasks,
    State,
    StatusPublisher,
    Transition
  }

  @spec run(Transition.t()) :: {term(), term() | nil}
  def run(%Transition{next_state: state, reply: reply, effects: effects}) do
    {next_state, reply} = Enum.reduce(effects, {state, reply}, &run_effect/2)
    {publish_send_changes(state, next_state, effects), reply}
  end

  # Incoming messages already publish at the end of their effects. Response
  # and push starts need a publication too, so in-flight sends are visible.
  defp publish_send_changes(previous, %State{enabled?: true} = state, effects) do
    if (previous.delivery.sends != state.delivery.sends or previous.health != state.health) and
         not Enum.any?(effects, &(&1.kind == :broadcast_status)) do
      StatusPublisher.publish(state)
    else
      state
    end
  end

  defp publish_send_changes(_previous, state, _effects), do: state

  defp run_effect(%Effect{kind: :reply, payload: {from, value}}, {state, reply}) do
    {state, value} = Exiron.Hub.Idempotency.finish(state, from, value)
    GenServer.reply(from, value)
    {state, reply}
  end

  defp run_effect(%Effect{kind: :broadcast_status}, {state, reply}) do
    {StatusPublisher.publish(state), reply}
  end

  defp run_effect(%Effect{kind: :deliver_socket_queues}, {state, reply}) do
    {ClientSessions.deliver_socket_queues(state), reply}
  end

  defp run_effect(%Effect{kind: :cancel_timer, payload: timer}, accumulator)
       when is_reference(timer) do
    Process.cancel_timer(timer)
    accumulator
  end

  defp run_effect(%Effect{kind: :cancel_timer}, accumulator), do: accumulator

  defp run_effect(%Effect{kind: :schedule, payload: {message, delay_ms}}, accumulator) do
    Process.send_after(self(), message, delay_ms)
    accumulator
  end

  defp run_effect(%Effect{kind: :terminate_task, payload: pid}, accumulator) do
    terminate_task(pid)
    accumulator
  end

  defp run_effect(%Effect{kind: :start_send, payload: payload}, {state, reply}) do
    case SendTasks.ensure_capacity(state, payload.command.hook, payload.command.payload_bytes) do
      :ok ->
        start_send(state, payload, reply)

      {:error, reason} ->
        {send_start_failed(state, payload, reason),
         start_send_failure_reply(payload, reason, reply)}
    end
  end

  defp start_send(state, payload, reply) do
    case SendTasks.start(state, payload.from, payload.command, payload.task) do
      {:ok, state} ->
        {state, reply}

      {:error, reason} ->
        {send_start_failed(state, payload, reason),
         start_send_failure_reply(payload, reason, reply)}
    end
  end

  defp send_start_failed(state, payload, reason) do
    # Background effects can start several tasks in one transition. A rejection
    # must retain tasks and counters created by earlier effects in that batch.
    state = if is_nil(payload.from), do: state, else: payload.failure_state

    if reason in [:send_queue_full, :hook_send_queue_full] do
      state
      |> SendTasks.capacity_rejected(payload.command.hook, payload.command.payload_bytes)
      |> Exiron.Hub.RequestTrace.record(payload.command.request_id, :send_capacity_rejected,
        status: :send_failed,
        detail: reason
      )
    else
      state
      |> DeliveryHealth.send_failed(payload.command.hook)
      |> Exiron.Hub.RequestTrace.record(payload.command.request_id, :send_could_not_start,
        status: :send_failed
      )
    end
  end

  defp start_send_failure_reply(%{failure_reply: :auto, from: from}, reason, _reply)
       when not is_nil(from),
       do: {:error, reason}

  defp start_send_failure_reply(%{failure_reply: failure_reply}, _reason, reply)
       when failure_reply != :auto,
       do: failure_reply || reply

  defp start_send_failure_reply(_payload, _reason, reply), do: reply

  defp terminate_task(pid) do
    case Task.Supervisor.terminate_child(Exiron.Hub.SendSupervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
