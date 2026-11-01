defmodule ExironClient.SocketDelivery do
  @moduledoc """
  Coordinates the single in-flight delivery worker used by a socket poller.

  Delegates worker ownership to `DeliveryWorker`, also used by graceful HTTP.
  Matching socket completions refresh the heartbeat timestamp here; WebSocket
  acknowledgements remain in `SocketPoller`.
  """

  alias ExironClient.{DeliveryWorker, SocketState}

  @spec ensure_worker(SocketState.t()) :: SocketState.t()
  defdelegate ensure_worker(state), to: DeliveryWorker, as: :ensure_started

  @spec enqueue(SocketState.t(), list(), binary() | nil) ::
          {:ok, SocketState.t()} | {:error, term()}
  defdelegate enqueue(state, messages, delivery_id), to: DeliveryWorker

  @spec complete(SocketState.t(), pid(), reference()) ::
          {:ok, binary() | nil, SocketState.t()}
  def complete(state, worker_pid, job_ref) do
    if state.worker_pid == worker_pid and state.worker_job_ref == job_ref do
      {:ok, delivery_id, state} = DeliveryWorker.complete(state, worker_pid, job_ref)
      {:ok, delivery_id, %{state | last_seen_ms: monotonic_ms()}}
    else
      {:ok, nil, state}
    end
  end

  @spec stop(SocketState.t()) :: :ok
  defdelegate stop(state), to: DeliveryWorker

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
