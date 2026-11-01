defmodule Exiron.Hub.ClientSessionsReconciliationTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ClientSessions, DeliveryState, PendingRequest, QueueBuffer, Router, State}

  test "router reconciliation prunes queues and pending timers for removed hooks" do
    removed_timer = Process.send_after(self(), :removed_request_expired, 60_000)
    retained_timer = Process.send_after(self(), :retained_request_expired, 60_000)
    on_exit(fn -> Process.cancel_timer(retained_timer) end)

    old_router = %Router{hooks: %{"removed" => "old-token", "retained" => "same-token"}}
    new_router = %Router{hooks: %{"retained" => "same-token"}}

    state = %State{
      router: old_router,
      delivery: %DeliveryState{
        queues: %{
          "removed" => QueueBuffer.from_items([%{msgtype: "listen", data: "sensitive"}]),
          "retained" => QueueBuffer.from_items([%{msgtype: "listen", data: "kept"}])
        },
        pending: %{
          "removed-request" => %PendingRequest{hook: "removed", timer: removed_timer},
          "retained-request" => %PendingRequest{hook: "retained", timer: retained_timer}
        }
      }
    }

    reconciled = ClientSessions.reconcile_router(state, old_router, new_router)

    refute Map.has_key?(reconciled.delivery.queues, "removed")
    refute Map.has_key?(reconciled.delivery.pending, "removed-request")

    assert QueueBuffer.items(reconciled.delivery.queues["retained"]) == [
             %{msgtype: "listen", data: "kept"}
           ]

    assert %PendingRequest{timer: ^retained_timer} =
             reconciled.delivery.pending["retained-request"]

    assert Process.read_timer(removed_timer) == false
    assert is_integer(Process.read_timer(retained_timer))
  end
end
