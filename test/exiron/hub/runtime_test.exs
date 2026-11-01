defmodule Exiron.Hub.RuntimeTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{
    ActivityState,
    ClientSessions,
    DeliveryState,
    QueueBuffer,
    Settings,
    State
  }

  test "drains client queues and records a single connect event" do
    state = %State{
      settings: Settings.from_options(client_timeout: 3_000),
      delivery: %DeliveryState{
        clients: %{"assistant" => %{client_id: "client", connected_at: nil, listen?: true}},
        queues: %{
          "assistant" => QueueBuffer.from_items([%{msgtype: "listen", req_id: "listen-1"}])
        }
      },
      activity: %ActivityState{}
    }

    {:ok, items, state} = ClientSessions.poll(state, "assistant", client_id: "client")

    assert [%{req_id: "listen-1"}] = items
    assert QueueBuffer.items(state.delivery.queues["assistant"]) == []
    assert [%{action: "connected", client_id: "client"}] = state.activity.client_events

    {:ok, [], state} = ClientSessions.poll(state, "assistant", client_id: "client")
    assert length(state.activity.client_events) == 1
    Process.cancel_timer(state.delivery.clients["assistant"].timer)
  end

  test "expire_client ignores stale leases" do
    state = %State{
      settings: Settings.from_options(client_timeout: 3_000),
      delivery: %DeliveryState{
        clients: %{"assistant" => %{client_id: "client", lease: make_ref()}}
      },
      activity: %ActivityState{}
    }

    assert ClientSessions.expire_client(state, "assistant", "client", make_ref()) == state
  end

  test "reset cancels client and pending request timers" do
    client_timer = Process.send_after(self(), :client_expired, 10_000)
    pending_timer = Process.send_after(self(), :request_expired, 10_000)

    state = %State{
      delivery: %DeliveryState{
        clients: %{
          "assistant" => %{
            client_id: "client",
            listen?: false,
            timer: client_timer,
            transport: :http
          }
        },
        pending: %{"request" => %{timer: pending_timer}},
        queues: %{"assistant" => QueueBuffer.new()}
      },
      activity: %ActivityState{}
    }

    reset = ClientSessions.reset(state)

    assert reset.delivery.clients == %{}
    assert reset.delivery.pending == %{}
    assert reset.delivery.queues == %{}
    refute Process.read_timer(client_timer)
    refute Process.read_timer(pending_timer)
  end
end
