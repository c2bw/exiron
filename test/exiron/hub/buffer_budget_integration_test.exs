defmodule Exiron.Hub.BufferBudgetIntegrationTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{BufferBudget, Message}

  test "routed work has priority over listen-all copies and overload preserves accepted work" do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: :all)
    :sys.replace_state(Hub, &put_in(&1.settings.max_buffered_bytes, 8))
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi"))
    snapshot = Hub.status()
    assert snapshot.buffer_capacity.bytes == 8
    assert snapshot.buffer_capacity.listener_rejections == 1
    assert snapshot.requested == 1
    pending = :sys.get_state(Hub).delivery.pending
    queues = :sys.get_state(Hub).delivery.queues

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai no"))
    assert :sys.get_state(Hub).delivery.pending == pending
    assert :sys.get_state(Hub).delivery.queues == queues

    assert %{request_rejections: 1, listener_rejections: 2, bytes: 8} =
             Hub.status().buffer_capacity

    assert [%{reason: :max_buffered_bytes} | _] = Hub.status().overload_events
    {:ok, scoped} = Hub.status_for_token("ai-token")
    refute Map.has_key?(scoped, :buffer_capacity)
  end

  test "HTTP batch retains its budget through retries, frees on acknowledgement and cancellation" do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :sys.replace_state(Hub, &put_in(&1.settings.max_buffered_bytes, 8))
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi"))
    {:ok, delivery} = Hub.poll_delivery("ai-token", client_id: "worker")
    assert %{bytes: 8, queued_bytes: 0, awaiting_ack_bytes: 8} = Hub.status().buffer_capacity
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai no"))
    assert Hub.status().buffer_capacity.request_rejections == 1
    assert {:ok, ^delivery} = Hub.poll_delivery("ai-token", client_id: "worker")

    {:ok, empty} =
      Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: delivery.delivery_id)

    assert empty.requests == []
    assert Hub.status().buffer_capacity.bytes == 0
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai ok"))
    {:ok, next} = Hub.poll_delivery("ai-token", client_id: "worker")
    [request] = next.requests
    assert {:ok, _} = Hub.cancel("ai-token", request.req_id)
    assert BufferBudget.snapshot(:sys.get_state(Hub)).bytes == 0
  end

  test "WebSocket disconnect requeues its accepted bytes without freeing capacity" do
    assert {:ok, %{messages: []}} =
             Hub.connect_socket("ai-token", client_id: "socket", listen: false, pid: self())

    :sys.replace_state(Hub, &put_in(&1.settings.max_buffered_bytes, 8))
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hi"))
    assert_receive {:exiron_messages, ref, [request]}
    assert Hub.status().buffer_capacity.awaiting_ack_bytes == 8
    Hub.disconnect_socket("assistant", "socket", self())
    assert %{bytes: 8, queued_bytes: 8, awaiting_ack_bytes: 0} = Hub.status().buffer_capacity

    assert {:ok, %{delivery_id: id, requests: [%{req_id: req_id}]}} =
             Hub.poll_delivery("ai-token", client_id: "worker")

    assert req_id == request.req_id
    assert Hub.status().buffer_capacity.bytes == 8
    Hub.complete_socket_delivery("assistant", "socket", self(), ref)
    assert Hub.status().buffer_capacity.bytes == 8

    assert {:ok, %{requests: []}} =
             Hub.poll_delivery("ai-token", client_id: "worker", delivery_ack: id)

    assert Hub.status().buffer_capacity.bytes == 0
  end
end
