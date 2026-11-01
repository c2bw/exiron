defmodule ExironClient.SocketWorker do
  @moduledoc false

  use GenServer

  alias ExironClient.MessageHandler

  def start_link(owner, handler, opts \\ []) when is_pid(owner) and is_function(handler, 1) do
    GenServer.start_link(__MODULE__, {owner, handler, opts})
  end

  def enqueue(worker, messages, delivery_id \\ nil) when is_pid(worker) and is_list(messages) do
    GenServer.call(worker, {:enqueue, messages, delivery_id}, :infinity)
  end

  @impl true
  def init({owner, handler, opts}) do
    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       handler: handler,
       handler_options: opts,
       pending: nil,
       status: :ready
     }}
  end

  @impl true
  def handle_call(
        {:enqueue, _messages, _delivery_id},
        _from,
        %{status: {:failed, reason}} = state
      ) do
    {:reply, {:error, reason}, state}
  end

  def handle_call(
        {:enqueue, messages, delivery_id},
        _from,
        %{pending: nil, status: :ready} = state
      ) do
    job_ref = make_ref()
    send(self(), {:handle, job_ref})

    {:reply, {:ok, job_ref}, %{state | pending: {job_ref, messages, delivery_id}}}
  end

  @impl true
  def handle_info(
        {:handle, job_ref},
        %{owner: owner, handler: handler, pending: {job_ref, messages, delivery_id}} = state
      ) do
    opts = Keyword.put(state.handler_options, :delivery_id, delivery_id)

    result =
      case opts[:batch_wrapper] do
        nil -> MessageHandler.handle(messages, handler, opts)
        wrapper -> wrapper.(messages, delivery_id, handler, opts)
      end

    case result do
      :ok ->
        send(owner, {:handler_complete, self(), job_ref})
        {:noreply, %{state | pending: nil}}

      {:error, reason} ->
        send(owner, {:handler_failed, self(), job_ref, reason})
        {:noreply, %{state | pending: nil, status: {:failed, reason}}}
    end
  end

  def handle_info(
        {:DOWN, owner_ref, :process, owner, _reason},
        %{owner: owner, owner_ref: owner_ref} = state
      ) do
    {:stop, :normal, state}
  end

  @impl true
  def format_status(status) do
    ExironClient.OTPStatus.redact(status, &status_state/1)
  end

  defp status_state(state) when is_map(state) do
    %{
      owner: state.owner,
      pending?: state.pending != nil,
      status: worker_status(state.status)
    }
  end

  defp status_state(_state), do: :redacted

  defp worker_status(:ready), do: :ready
  defp worker_status({:failed, _reason}), do: :failed
end
