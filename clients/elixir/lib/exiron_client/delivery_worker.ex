defmodule ExironClient.DeliveryWorker do
  @moduledoc false

  # HTTP and WebSocket own the same single batch worker. Only job ownership is
  # shared here; acknowledgements, leases and socket activity belong to adapters.
  alias ExironClient.SocketWorker

  def ensure_started(state, handler_options \\ nil)

  def ensure_started(%{worker_pid: pid} = state, _options) when is_pid(pid), do: state

  def ensure_started(state, handler_options) do
    {:ok, pid} =
      SocketWorker.start_link(self(), state.handler, handler_options || state.handler_options)

    %{state | worker_pid: pid, worker_monitor_ref: Process.monitor(pid)}
  end

  def enqueue(state, messages, delivery_id) do
    state = ensure_started(state)

    with {:ok, ref} <- SocketWorker.enqueue(state.worker_pid, messages, delivery_id) do
      {:ok, %{state | worker_job_ref: ref, worker_delivery_id: delivery_id}}
    end
  end

  def complete(%{worker_pid: pid, worker_job_ref: ref} = state, pid, ref) do
    {:ok, state.worker_delivery_id, %{state | worker_job_ref: nil, worker_delivery_id: nil}}
  end

  def complete(state, _pid, _ref), do: {:ok, nil, state}

  def active?(state), do: is_reference(state.worker_job_ref)

  def stop(%{worker_pid: pid, worker_monitor_ref: monitor}) when is_pid(pid) do
    if is_reference(monitor), do: Process.demonitor(monitor, [:flush])
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    :ok
  end

  def stop(_state), do: :ok
end
