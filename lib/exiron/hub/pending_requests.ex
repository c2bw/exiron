defmodule Exiron.Hub.PendingRequests do
  @moduledoc false

  alias Exiron.Hub.{Identifier, Message, PendingRequest, RequestQueue}

  def take(state, request_id, hook) do
    with :ok <- Exiron.Hub.RequestCancellation.check(state, request_id, hook) do
      state.delivery.pending |> Map.fetch(request_id) |> take_result(hook)
    end
  end

  def delete(state, request_id) do
    %{
      state
      | delivery: %{state.delivery | pending: Map.delete(state.delivery.pending, request_id)}
    }
  end

  def mark_responding(state, request_id) do
    update_in(state.delivery.pending[request_id], &PendingRequest.start_response/1)
  end

  def clear_responding(state, request_id) do
    case Map.fetch(state.delivery.pending, request_id) do
      {:ok, %PendingRequest{} = pending} ->
        %{
          state
          | delivery: %{
              state.delivery
              | pending:
                  Map.put(
                    state.delivery.pending,
                    request_id,
                    PendingRequest.clear_response(pending)
                  )
            }
        }

      {:ok, pending} when is_map(pending) ->
        %{
          state
          | delivery: %{
              state.delivery
              | pending:
                  Map.put(state.delivery.pending, request_id, Map.delete(pending, :responding?))
            }
        }

      {:ok, nil} ->
        %{
          state
          | delivery: %{
              state.delivery
              | pending: Map.delete(state.delivery.pending, request_id)
            }
        }

      :error ->
        state
    end
  end

  def expire(state, request_id) do
    case Map.pop(state.delivery.pending, request_id) do
      {nil, _pending} ->
        {:unchanged, state}

      {%{hook: hook}, pending} ->
        state = %{state | delivery: %{state.delivery | pending: pending}}

        state =
          state
          |> RequestQueue.remove(hook, request_id)
          |> Exiron.Hub.RequestControl.expired(request_id, hook)
          |> Exiron.Hub.RequestTrace.record(request_id, :expired, status: :expired)

        {:expired, state}
    end
  end

  def create(state, message, hook, timeout, opts \\ []) do
    request_id = request_id()
    timer = Process.send_after(self(), {:expire_request, request_id}, timeout)

    pending = %{
      PendingRequest.new(message, hook, timer)
      | interaction_context: Exiron.Hub.ConversationRouting.context(message, opts[:route])
    }

    state =
      state
      |> put_in(
        [Access.key!(:delivery), Access.key!(:pending), request_id],
        pending
      )
      |> RequestQueue.enqueue(hook, Message.to_client(message, request_id))

    state = Exiron.Hub.RequestTrace.start(state, request_id, message, hook, opts[:route_id])
    {request_id, state}
  end

  def request_id, do: Identifier.new()

  defp take_result({:ok, %PendingRequest{} = pending}, hook) do
    if PendingRequest.assigned_to?(pending, hook) and PendingRequest.responding?(pending) do
      {:error, :request_in_flight}
    else
      if PendingRequest.assigned_to?(pending, hook),
        do: {:ok, pending},
        else: {:error, :request_not_assigned}
    end
  end

  defp take_result({:ok, %{hook: hook, responding?: true}}, hook),
    do: {:error, :request_in_flight}

  defp take_result({:ok, %{hook: hook} = pending}, hook), do: {:ok, pending}
  defp take_result({:ok, _pending}, _hook), do: {:error, :request_not_assigned}
  defp take_result(:error, _hook), do: {:error, :request_not_found}
end
