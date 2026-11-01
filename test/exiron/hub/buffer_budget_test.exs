defmodule Exiron.Hub.BufferBudgetTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{
    BufferBudget,
    ClientDeliveries,
    ClientSession,
    Delivery,
    DeliveryState,
    Message,
    QueueBuffer,
    QueueState,
    RequestQueue,
    Settings,
    State
  }

  test "global admission includes other hooks and exact equality is allowed" do
    state = state(8, %{"a" => QueueBuffer.from_items([item("one")])})
    message = Message.new(222, 123, "text", "two")
    assert RequestQueue.available?(state, "b", message) == :ok
    state = put_in(state.settings.max_buffered_bytes, 7)
    assert RequestQueue.available?(state, "b", message) == {:error, :max_buffered_bytes}
    assert BufferBudget.snapshot(state).bytes == 4
  end

  test "usage counts every queue and HTTP and WebSocket unacknowledged payload" do
    state = state(12, %{"a" => QueueBuffer.from_items([item("one")])})

    clients = %{
      "http" => %ClientSession{http_delivery: Delivery.new([item("two")])},
      "ws" => %ClientSession{transport: :websocket, socket_delivery: Delivery.new([item("tri")])}
    }

    state = put_in(state.delivery.clients, clients)

    assert %{bytes: 12, queued_bytes: 4, awaiting_ack_bytes: 8, limit: 12} =
             BufferBudget.snapshot(state)

    refute BufferBudget.available?(state, 1)
  end

  test "moving a queue into delivery does not free or double count bytes; acknowledgement frees it" do
    state = state(4, %{"a" => QueueBuffer.from_items([item("one")])})
    state = put_in(state.delivery.clients, %{"a" => %ClientSession{client_id: "worker"}})
    {:ok, ref, [_], state} = ClientDeliveries.poll_delivery(state, "a", nil)
    assert %{bytes: 4, queued_bytes: 0, awaiting_ack_bytes: 4} = BufferBudget.snapshot(state)
    {:ok, ^ref, [_], repeated} = ClientDeliveries.poll_delivery(state, "a", nil)
    assert BufferBudget.snapshot(repeated).bytes == 4
    {:ok, nil, [], state} = ClientDeliveries.poll_delivery(state, "a", ref)
    assert BufferBudget.snapshot(state).bytes == 0
    assert BufferBudget.available?(state, 4)
  end

  test "global rejection leaves accepted queues intact and counts each listener copy" do
    queue = QueueBuffer.from_items([item("one")])
    state = state(4, %{"a" => queue})

    {next, 1} =
      QueueState.queue_listener_message(state, "b", Message.new(222, 123, "text", "two"))

    assert next.delivery.queues == state.delivery.queues

    assert %{listener_rejections: 1, request_rejections: 0, bytes: 4} =
             BufferBudget.snapshot(next)
  end

  test "listener churn cannot evict an accepted routed request at the per-hook limit" do
    request = Map.merge(item("one"), %{msgtype: "request", req_id: "accepted"})
    state = state(100, %{"a" => QueueBuffer.from_items([request])})
    state = put_in(state.settings.max_queue_per_hook, 1)

    {next, 1} =
      QueueState.queue_listener_message(state, "a", Message.new(222, 123, "text", "two"))

    assert next.delivery.queues == state.delivery.queues
    assert next.delivery.buffer_rejections.listeners == 0
  end

  test "lowering a limit never evicts already buffered work" do
    state = state(3, %{"a" => QueueBuffer.from_items([item("one")])})
    refute BufferBudget.available?(state, 0)

    {next, 1} =
      QueueState.queue_listener_message(state, "a", Message.new(222, 123, "text", "two"))

    assert BufferBudget.snapshot(next).bytes == 4
    assert next.delivery.queues == state.delivery.queues
  end

  defp state(limit, queues) do
    %State{
      settings: Settings.from_options(max_buffered_bytes: limit),
      delivery: %DeliveryState{queues: queues}
    }
  end

  defp item(text), do: %{msgtype: "listen", data: Base.encode64(text)}
end
