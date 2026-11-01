defmodule Exiron.Hub.RequestQueue do
  @moduledoc false

  alias Exiron.Hub.{Message, PendingRequest, Queue, QueueBuffer}

  def enqueue(state, hook, message) do
    buffer = Map.get(state.delivery.queues, hook, QueueBuffer.new())
    {buffer, _dropped} = QueueBuffer.push(buffer, message, Queue.routed_bounds(state, hook))
    %{state | delivery: %{state.delivery | queues: Map.put(state.delivery.queues, hook, buffer)}}
  end

  def remove(state, hook, request_id) do
    case Map.fetch(state.delivery.queues, hook) do
      {:ok, queue} ->
        queue = QueueBuffer.remove(queue, &request_item?(&1, request_id))

        %{
          state
          | delivery: %{state.delivery | queues: Map.put(state.delivery.queues, hook, queue)}
        }

      :error ->
        state
    end
  end

  def available?(state, hook, %Message{} = message) do
    Queue.available?(state, hook, message)
  end

  def claim(state, items), do: update_claims(state, items, true)
  def unclaim(state, items), do: update_claims(state, items, false)

  def pending_items(pending, items) do
    Enum.filter(items, fn
      %{msgtype: "request", req_id: request_id} when is_binary(request_id) ->
        Map.has_key?(pending, request_id)

      _item ->
        false
    end)
  end

  defp update_claims(state, items, claimed?) do
    pending =
      items
      |> request_ids()
      |> Enum.reduce(state.delivery.pending, &put_claim(&2, &1, claimed?, state.delivery.clients))

    %{state | delivery: %{state.delivery | pending: pending}}
  end

  defp put_claim(pending, request_id, claimed?, clients) do
    case Map.fetch(pending, request_id) do
      {:ok, %PendingRequest{} = request} ->
        request =
          if claimed?, do: PendingRequest.claim(request), else: PendingRequest.unclaim(request)

        request = if claimed?, do: recipient(request, clients), else: request
        Map.put(pending, request_id, request)

      {:ok, request} ->
        request = Map.put(request, :claimed?, claimed?)
        Map.put(pending, request_id, if(claimed?, do: recipient(request, clients), else: request))

      :error ->
        pending
    end
  end

  defp recipient(request, clients) do
    client = Map.get(clients, Map.get(request, :hook)) || %{}

    request
    |> Map.put(:assigned_client_id, Map.get(client, :client_id))
    |> Map.put(:assigned_client_transport, Map.get(client, :transport))
  end

  defp request_ids(items) do
    Enum.reduce(items, MapSet.new(), fn
      %{msgtype: "request", req_id: request_id}, request_ids ->
        MapSet.put(request_ids, request_id)

      _item, request_ids ->
        request_ids
    end)
  end

  defp request_item?(%{msgtype: "request", req_id: request_id}, request_id), do: true
  defp request_item?(_item, _request_id), do: false
end
