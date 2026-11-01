defmodule ExironClient.ClientDrain do
  @moduledoc false

  def drain(pid, timeout) when is_pid(pid) and is_integer(timeout) and timeout > 0 do
    ref = make_ref()
    reply_to = :erlang.alias()
    deadline = now() + timeout
    monitor = Process.monitor(pid)
    send(pid, {:client_drain, reply_to, ref, deadline})

    try do
      receive do
        {:client_drain_result, ^ref, :ok} ->
          receive do
            {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
            {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, reason}
          after
            max(deadline - now(), 0) -> {:error, :drain_timeout}
          end

        {:client_drain_result, ^ref, result} ->
          result

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, reason}
      after
        max(deadline - now(), 0) -> {:error, :drain_timeout}
      end
    after
      :erlang.unalias(reply_to)
      Process.demonitor(monitor, [:flush])
    end
  end

  def drain(_, _), do: raise(ArgumentError, "drain requires a pid and positive timeout_ms")
  def now, do: System.monotonic_time(:millisecond)

  def start(from, ref, deadline) do
    %{
      from: from,
      ref: ref,
      deadline: deadline,
      timer: Process.send_after(self(), {:client_drain_timeout, ref}, max(deadline - now(), 0))
    }
  end

  # Return state transitions independently of GenServer/WebSockex return tuples.
  def begin_drain(%{graceful_shutdown: false}, from, ref, _deadline),
    do: reject(from, ref, :graceful_shutdown_disabled)

  def begin_drain(%{client_drain: nil} = state, from, ref, deadline) do
    state = %{state | client_drain: start(from, ref, deadline)}
    ExironClient.RuntimeStatus.drain(state, deadline)
    {:ok, state}
  end

  def begin_drain(_state, from, ref, _deadline), do: reject(from, ref, :already_draining)

  defp reject(from, ref, reason) do
    send(from, {:client_drain_result, ref, {:error, reason}})
    {:error, reason}
  end

  def finish(%{client_drain: nil} = state, _result), do: state
  def finish(%{client_drain: %{replied: true}} = state, _result), do: state

  def finish(state, result) do
    reply(state.client_drain, result)
    %{state | client_drain: Map.put(state.client_drain, :replied, true)}
  end

  def reply(nil, _), do: :ok

  def reply(drain, result) do
    Process.cancel_timer(drain.timer)
    send(drain.from, {:client_drain_result, drain.ref, result})
  end

  def retire(_client, nil, drain),
    do: if(drain.deadline > now(), do: :ok, else: {:error, :drain_timeout})

  def retire(client, id, drain) do
    budget = min(max(drain.deadline - now(), 0), 1000)

    if budget == 0 do
      {:error, :drain_timeout}
    else
      task = Task.async(fn -> request(client, id, budget) end)

      case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :drain_timeout}
      end
    end
  end

  def request(client, id, budget) do
    try do
      ExironClient.retire_delivery(client, id, receive_timeout: budget, pool_timeout: budget)
    rescue
      _ -> {:error, ExironClient.Error.new(:request_error, "client retirement failed")}
    catch
      _, _ -> {:error, ExironClient.Error.new(:request_error, "client retirement failed")}
    end
  end
end
