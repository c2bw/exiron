defmodule Exiron.Hub.ClientDeliveriesTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{
    ClientDeliveries,
    ClientState,
    Delivery,
    DeliveryState,
    QueueBuffer,
    Settings,
    State
  }

  test "socket delivery stores a typed batch" do
    state =
      base_state()
      |> ClientState.put("assistant", "socket", false, make_ref(), nil, transport: :websocket)
      |> put_in(
        [Access.key!(:delivery), Access.key!(:queues)],
        %{
          "assistant" => QueueBuffer.from_items([%{msgtype: "request", req_id: "request-1"}])
        }
      )

    assert {:ok, delivery_id, [_request], state} =
             ClientDeliveries.start_socket_delivery(state, "assistant")

    assert %Delivery{ref: ^delivery_id, items: [%{req_id: "request-1"}], count: 1} =
             state.delivery.clients["assistant"].socket_delivery
  end

  test "drains FIFO items and claims routed requests" do
    state = %{
      base_state()
      | delivery: %DeliveryState{
          queues: %{
            "assistant" =>
              QueueBuffer.from_items([
                %{msgtype: "request", req_id: "request-2"},
                %{msgtype: "listen", req_id: "listen-1"},
                %{msgtype: "request", req_id: "request-1"}
              ])
          },
          pending: %{
            "request-1" => %{hook: "assistant", claimed?: false},
            "request-2" => %{hook: "assistant", claimed?: false},
            "other" => %{hook: "assistant", claimed?: false}
          }
        }
    }

    {items, state} = ClientDeliveries.drain_queue(state, "assistant")

    assert Enum.map(items, & &1.req_id) == ["request-1", "listen-1", "request-2"]
    assert QueueBuffer.items(state.delivery.queues["assistant"]) == []
    assert state.delivery.pending["request-1"].claimed?
    assert state.delivery.pending["request-2"].claimed?
    refute state.delivery.pending["other"].claimed?
  end

  test "requeues routed work but drops lossy listen items" do
    request = %{msgtype: "request", req_id: "request-1"}
    listen = %{msgtype: "listen", req_id: "listen-1"}
    delivery = Delivery.new([request, listen])

    state =
      base_state()
      |> ClientState.put("assistant", "socket", false, make_ref(), nil, transport: :websocket)
      |> put_in(
        [Access.key!(:delivery), Access.key!(:pending), "request-1"],
        %{hook: "assistant", claimed?: true}
      )
      |> update_in(
        [Access.key!(:delivery), Access.key!(:clients), "assistant"],
        &%{&1 | socket_delivery: delivery}
      )
      |> ClientDeliveries.requeue_unacknowledged("assistant")

    assert QueueBuffer.items(state.delivery.queues["assistant"]) == [request]
    refute state.delivery.pending["request-1"].claimed?
  end

  defp base_state do
    %State{
      settings: Settings.from_options(client_timeout: 3_000),
      delivery: %DeliveryState{}
    }
  end
end
