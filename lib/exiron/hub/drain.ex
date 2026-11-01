defmodule Exiron.Hub.Drain do
  @moduledoc false
  alias Exiron.Hub.{Delivery, Effect, Transition}

  defstruct active?: false,
            started_at: nil,
            timeout_ms: nil,
            timer: nil,
            generation: nil,
            timed_out?: false

  @type t :: %__MODULE__{}

  def start(%{enabled?: false} = state, _opts),
    do: Transition.reply(state, {:error, :disabled})

  def start(state, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)

    cond do
      not is_integer(timeout) or timeout < 1 or timeout > 3_600_000 ->
        Transition.reply(state, {:error, :invalid_payload})

      state.drain.active? ->
        Transition.reply(state, {:ok, snapshot(state)})

      true ->
        generation = make_ref()
        timer = Process.send_after(self(), {:drain_timeout, generation}, timeout)

        drain = %__MODULE__{
          active?: true,
          started_at: DateTime.utc_now(),
          timeout_ms: timeout,
          timer: timer,
          generation: generation
        }

        state = %{state | drain: drain}
        Transition.new(state, reply: {:ok, snapshot(state)}, effects: [Effect.broadcast_status()])
    end
  end

  def resume(state) do
    if state.drain.timer, do: Process.cancel_timer(state.drain.timer)
    state = %{state | drain: %__MODULE__{}}
    Transition.new(state, reply: :ok, effects: [Effect.broadcast_status()])
  end

  def timeout(%{drain: %{active?: true, generation: generation}} = state, generation) do
    state = %{state | drain: %{state.drain | timed_out?: true, timer: nil}}
    Transition.new(state, effects: [Effect.broadcast_status()])
  end

  def timeout(state, _generation), do: Transition.new(state)
  def admit(%{drain: %{active?: true}}), do: {:error, :draining}
  def admit(_state), do: :ok

  def snapshot(state) do
    counts = %{
      pending_requests: map_size(state.delivery.pending),
      queued_messages: Enum.sum_by(state.delivery.queues, fn {_, queue} -> queue.count end),
      active_sends: map_size(state.delivery.sends),
      unacknowledged_batches:
        Enum.sum_by(state.delivery.clients, fn {_, client} ->
          Enum.count([client.http_delivery, client.socket_delivery], &match?(%Delivery{}, &1))
        end)
    }

    empty? = Enum.all?(counts, fn {_, count} -> count == 0 end)

    phase =
      cond do
        not state.drain.active? -> "running"
        empty? -> "drained"
        state.drain.timed_out? -> "timed_out"
        true -> "draining"
      end

    Map.merge(counts, %{
      active: state.drain.active?,
      phase: phase,
      drained: state.drain.active? and empty?,
      started_at: state.drain.started_at,
      timeout_ms: state.drain.timeout_ms
    })
  end
end
