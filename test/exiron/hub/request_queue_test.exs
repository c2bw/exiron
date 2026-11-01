defmodule Exiron.Hub.RequestQueueTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Delivery, DeliveryState, Message, QueueBuffer, RequestQueue, Settings, State}

  test "claims and unclaims only queued request items" do
    state = %State{
      delivery: %DeliveryState{
        pending: %{
          "first" => %{claimed?: false},
          "second" => %{claimed?: false}
        }
      }
    }

    items = [
      %{msgtype: "request", req_id: "first"},
      %{msgtype: "listen", req_id: "second"},
      %{msgtype: "request", req_id: "missing"}
    ]

    claimed = RequestQueue.claim(state, items)
    assert claimed.delivery.pending["first"].claimed?
    refute claimed.delivery.pending["second"].claimed?

    unclaimed = RequestQueue.unclaim(claimed, items)
    refute unclaimed.delivery.pending["first"].claimed?
  end

  test "admission includes queued and in-flight delivery usage" do
    message = Message.new(222, 123, "text", "hello")

    state = %State{
      delivery: %DeliveryState{
        queues: %{"assistant" => QueueBuffer.new()},
        clients: %{
          "assistant" => %{
            socket_delivery: %Delivery{count: 1, bytes: 8},
            http_delivery: nil
          }
        }
      },
      settings:
        Settings.from_options(
          max_pending: 10,
          max_queue_per_hook: 1,
          max_queue_bytes_per_hook: 100
        )
    }

    assert RequestQueue.available?(state, "assistant", message) ==
             {:error, :max_queue_per_hook}
  end

  test "retains only request items that are still pending" do
    items = [
      %{msgtype: "request", req_id: "pending"},
      %{msgtype: "request", req_id: "expired"},
      %{msgtype: "listen", req_id: "pending"}
    ]

    assert RequestQueue.pending_items(%{"pending" => %{}}, items) == [
             %{msgtype: "request", req_id: "pending"}
           ]
  end
end
