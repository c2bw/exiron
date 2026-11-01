defmodule Exiron.Hub.ClientStateTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{
    ActivityState,
    ClientSession,
    ClientState,
    DeliveryState,
    QueueBuffer,
    RequestQueue,
    Settings,
    State
  }

  import Exiron.Support.RouterHelper

  setup do
    %{router: load_router!("client-state")}
  end

  test "client lease conflict and same-client renewal", %{router: router} do
    old_timer = Process.send_after(self(), :old_expiry, 10_000)
    new_timer = Process.send_after(self(), :new_expiry, 10_000)

    state =
      ClientState.put(base_state(router), "assistant", "listener", true, make_ref(), old_timer)

    assert :ok = ClientState.ensure_available(state, "assistant", "listener")

    assert {:error, {:hook_already_connected, retry_after_ms}} =
             ClientState.ensure_available(state, "assistant", "worker")

    assert retry_after_ms in 1..10_000

    renewed = ClientState.put(state, "assistant", "listener", false, make_ref(), new_timer)
    assert renewed.delivery.clients["assistant"].client_id == "listener"
    refute renewed.delivery.clients["assistant"].listen?

    Process.cancel_timer(old_timer)
    Process.cancel_timer(new_timer)
  end

  test "stores typed client sessions", %{router: router} do
    timer = Process.send_after(self(), :test_expiry, 10_000)
    state = ClientState.put(base_state(router), "assistant", "listener", true, make_ref(), timer)

    assert %ClientSession{http_delivery: nil, socket_delivery: nil} =
             state.delivery.clients["assistant"]

    Process.cancel_timer(timer)
  end

  test "preserves unrelated queue items when removing a request", %{router: router} do
    state =
      router
      |> base_state()
      |> put_in(
        [Access.key!(:delivery), Access.key!(:queues)],
        %{
          "assistant" =>
            QueueBuffer.from_items([
              %{msgtype: "request", req_id: "request-2"},
              %{msgtype: "listen", req_id: "request-1"},
              %{msgtype: "request", req_id: "request-1"}
            ]),
          "other" => QueueBuffer.from_items([%{msgtype: "request", req_id: "request-1"}])
        }
      )

    state = RequestQueue.remove(state, "assistant", "request-1")
    {items, state} = ClientState.drain_queue(state, "assistant")

    assert Enum.map(items, &{&1.msgtype, &1.req_id}) == [
             {"listen", "request-1"},
             {"request", "request-2"}
           ]

    assert QueueBuffer.items(state.delivery.queues["other"]) == [
             %{msgtype: "request", req_id: "request-1"}
           ]
  end

  defp base_state(router) do
    %State{
      router: router,
      delivery: %DeliveryState{},
      activity: %ActivityState{},
      settings:
        Settings.from_options(
          max_queue_per_hook: 100,
          max_queue_bytes_per_hook: 50 * 1024 * 1024,
          max_pending: 1_000
        )
    }
  end
end
