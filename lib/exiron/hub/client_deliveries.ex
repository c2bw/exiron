defmodule Exiron.Hub.ClientDeliveries do
  @moduledoc false

  alias Exiron.Hub.{ClientSession, Delivery, QueueBuffer, RequestQueue}

  def remove_request(state, hook, id) do
    case Map.get(state.delivery.clients, hook) do
      nil ->
        state

      client ->
        client =
          Enum.reduce([:http_delivery, :socket_delivery], client, fn field, client ->
            case Map.get(client, field) do
              %Delivery{} = delivery ->
                items =
                  Enum.reject(delivery.items, &match?(%{msgtype: "request", req_id: ^id}, &1))

                value =
                  if items == [] and field == :http_delivery,
                    do: nil,
                    else: %{
                      delivery
                      | items: items,
                        count: length(items),
                        bytes: QueueBuffer.bytes(items)
                    }

                Map.put(client, field, value)

              _ ->
                client
            end
          end)

        put_in(state.delivery.clients[hook], client)
    end
  end

  def drain_queue(state, hook) do
    {queue, queues} =
      Map.get_and_update(state.delivery.queues, hook, fn queue ->
        {queue || QueueBuffer.new(), QueueBuffer.new()}
      end)

    {items, _empty} = QueueBuffer.drain(queue)

    state =
      state
      |> put_in([Access.key!(:delivery), Access.key!(:queues)], queues)
      |> RequestQueue.claim(items)
      |> Exiron.Hub.RequestTrace.items(items, :client_delivered,
        client_id: client_id(state, hook),
        status: :delivered
      )

    {items, state}
  end

  def start_socket_delivery(state, hook) do
    case client(state, hook) do
      %ClientSession{transport: :websocket, socket_delivery: nil} ->
        {items, state} = drain_queue(state, hook)
        put_socket_delivery(state, hook, items)

      %ClientSession{transport: :websocket} ->
        {:busy, state}

      _client ->
        {:empty, state}
    end
  end

  def poll_delivery(state, hook, acknowledgement) do
    case client(state, hook) do
      %ClientSession{transport: :http, http_delivery: %Delivery{ref: ^acknowledgement}} ->
        state
        |> Exiron.Hub.RequestTrace.items(
          client(state, hook).http_delivery.items,
          :client_acknowledged,
          status: :awaiting_response
        )
        |> put_in(
          [Access.key!(:delivery), Access.key!(:clients), hook, Access.key!(:last_ack_ref)],
          acknowledgement
        )
        |> put_delivery(hook, :http_delivery, nil)
        |> start_http_delivery(hook)

      %ClientSession{transport: :http, http_delivery: %Delivery{ref: ref, items: items}} ->
        state = put_in(state.delivery.clients[hook].http_batch_ref, ref)

        state =
          Exiron.Hub.RequestTrace.items(state, items, :client_delivered,
            client_id: client_id(state, hook),
            status: :delivered,
            detail: "Unacknowledged HTTP batch replayed"
          )

        {:ok, ref, items, state}

      %ClientSession{transport: :http, http_delivery: nil} ->
        start_http_delivery(state, hook)
    end
  end

  def complete_socket_delivery(state, hook, client_id, pid, delivery_ref) do
    case client(state, hook) do
      %ClientSession{
        client_id: ^client_id,
        pid: ^pid,
        transport: :websocket,
        socket_delivery: %Delivery{ref: ^delivery_ref}
      } ->
        state =
          Exiron.Hub.RequestTrace.items(
            state,
            client(state, hook).socket_delivery.items,
            :client_acknowledged,
            status: :awaiting_response
          )

        state = put_in(state.delivery.clients[hook].last_ack_ref, delivery_ref)
        {:completed, put_delivery(state, hook, :socket_delivery, nil)}

      _client ->
        {:stale, state}
    end
  end

  def requeue_unacknowledged(state, hook) do
    case client(state, hook) do
      %ClientSession{socket_delivery: %Delivery{items: items}} when is_list(items) ->
        requeue_delivery_items(state, hook, items)

      %ClientSession{http_delivery: %Delivery{items: items}} when is_list(items) ->
        requeue_delivery_items(state, hook, items)

      _client ->
        state
    end
  end

  defp put_socket_delivery(state, _hook, []), do: {:empty, state}

  defp put_socket_delivery(state, hook, items) do
    delivery = Delivery.new(items)
    {:ok, delivery.ref, items, put_delivery(state, hook, :socket_delivery, delivery)}
  end

  defp start_http_delivery(state, hook) do
    case drain_queue(state, hook) do
      {[], state} ->
        {:ok, nil, [], put_in(state.delivery.clients[hook].http_batch_ref, nil)}

      {items, state} ->
        delivery = Delivery.new(items)
        {:ok, delivery.ref, items, put_delivery(state, hook, :http_delivery, delivery)}
    end
  end

  defp put_delivery(state, hook, :http_delivery, delivery) do
    state = put_in(state.delivery.clients[hook].http_delivery, delivery)
    put_in(state.delivery.clients[hook].http_batch_ref, if(delivery, do: delivery.ref))
  end

  defp put_delivery(state, hook, field, delivery) do
    update_in(
      state,
      [Access.key!(:delivery), Access.key!(:clients), hook],
      &Map.put(&1, field, delivery)
    )
  end

  defp requeue_delivery_items(state, hook, items) do
    # Routed requests are delivered at least once; listen messages are lossy
    # and therefore excluded when an unacknowledged delivery is recovered.
    items = RequestQueue.pending_items(state.delivery.pending, items)

    state
    |> Exiron.Hub.RequestTrace.items(items, :requeued, status: :queued)
    |> prepend_queue(hook, items)
    |> RequestQueue.unclaim(items)
  end

  defp prepend_queue(state, _hook, []), do: state

  defp prepend_queue(state, hook, items) do
    queued_items = Enum.reverse(items)

    update_in(state.delivery.queues, fn queues ->
      Map.update(
        queues,
        hook,
        QueueBuffer.from_items(queued_items),
        &QueueBuffer.prepend(&1, items)
      )
    end)
  end

  defp client_id(state, hook) do
    case client(state, hook) do
      %{client_id: id} -> id
      _ -> nil
    end
  end

  defp client(state, hook), do: Map.get(state.delivery.clients, hook)
end
