defmodule Exiron.Hub.DeliveryHealthTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{ClientSessions, DeliveryHealth, Message, State, Status, Telegram}
  import Exiron.Support.RouterHelper

  setup do
    router = load_router!("delivery-health")

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _token, _message -> :ok end
      )

    :ok = Hub.configure(router, telegram)
    %{router: router, telegram: telegram}
  end

  test "offline rejections accumulate without creating pending work" do
    for _id <- 1..55 do
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    end

    status = Hub.status()
    assert status.delivery_health.unavailable_rejections == 55
    assert status.delivery_health.pending == 0
    assert status.delivery_health.completed_responses == 0
    assert [%{health: %{unavailable_rejections: 55}}] = status.hooks
  end

  test "connection timestamps survive disconnect and do not change on repeated polls" do
    assert {:ok, []} = Hub.poll("ai-token")
    [first] = Hub.status().hooks
    assert %DateTime{} = first.health.last_connected_at
    assert first.health.last_disconnected_at == nil

    assert {:ok, []} = Hub.poll("ai-token")
    assert [again] = Hub.status().hooks
    assert again.health.last_connected_at == first.health.last_connected_at

    client = :sys.get_state(Hub).delivery.clients["assistant"]
    send(Hub, {:expire_client, "assistant", client.client_id, client.lease})
    [disconnected] = Hub.status().hooks
    refute disconnected.connected
    assert disconnected.health.last_connected_at == first.health.last_connected_at
    assert %DateTime{} = disconnected.health.last_disconnected_at
  end

  test "successful response latency includes time since acceptance and is counted once" do
    assert {:ok, []} = Hub.poll("ai-token")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    assert {:ok, [request]} = Hub.poll("ai-token")

    # Model one second of client processing without delaying the test.
    :sys.replace_state(Hub, fn state ->
      put_in(
        state.delivery.pending[request.req_id].accepted_at,
        System.monotonic_time() - System.convert_time_unit(1, :second, :native)
      )
    end)

    assert :ok = Hub.respond("ai-token", request.req_id, "text", "reply")
    status = Hub.status()
    assert status.delivery_health.completed_responses == 1
    assert status.delivery_health.average_response_ms >= 1000
    assert status.delivery_health.pending == 0
    assert status.delivery_health.in_flight_sends == 0
    assert {:error, :request_not_found} = Hub.respond("ai-token", request.req_id, "text", "reply")
    assert Hub.status().delivery_health.completed_responses == 1
  end

  test "failed reply attempts count without being reported as successful responses", %{
    router: router
  } do
    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _token, _message -> {:error, :send_unavailable} end
      )

    :ok = Hub.configure(router, telegram)
    assert {:ok, []} = Hub.poll("ai-token")
    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
    assert {:ok, [request]} = Hub.poll("ai-token")

    for _attempt <- 1..2 do
      assert {:error, :send_unavailable} =
               Hub.respond("ai-token", request.req_id, "text", "reply")
    end

    assert %{send_failures: 2, completed_responses: 0, average_response_ms: nil, pending: 1} =
             Hub.status().delivery_health
  end

  test "removed hooks release counters and stale updates cannot recreate them", %{router: router} do
    state =
      %State{enabled?: true, router: router}
      |> DeliveryHealth.reject("assistant", :unavailable)

    assert map_size(state.health) == 1
    {:ok, empty_router} = Exiron.Hub.Router.load_definitions(%{})

    state =
      ClientSessions.reconcile_router(state, router, empty_router)
      |> Map.put(:router, empty_router)
      |> DeliveryHealth.send_failed("assistant")

    assert state.health == %{}
    assert Status.snapshot(state, "test").delivery_health.unavailable_rejections == 0
  end

  test "overload rejection and payload backlog are visible without accepting excess work" do
    :sys.replace_state(Hub, fn state ->
      %{state | settings: %{state.settings | max_pending: 1}}
    end)

    assert {:ok, []} = Hub.poll("ai-token")
    message = Message.new(222, 123, "text", "/ai hello", "bot-token")
    :ok = Hub.incoming_service_message(message)
    :ok = Hub.incoming_service_message(message)

    health = Hub.status().delivery_health
    assert health.overload_rejections == 1
    assert health.unavailable_rejections == 0
    assert health.pending == 1
    assert health.queued == 1
    assert health.queued_bytes > 0
  end

  test "real operations emit queue, pending, send and response measurements" do
    events = [
      [:exiron, :hub, :queue],
      [:exiron, :hub, :pending],
      [:exiron, :hub, :sends],
      [:exiron, :hub, :send, :stop],
      [:exiron, :hub, :response, :stop],
      [:exiron, :hub, :delivery, :rejected]
    ]

    handler = {__MODULE__, self()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:metric, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    message = Message.new(222, 123, "text", "/ai hello", "bot-token")
    :ok = Hub.incoming_service_message(message)

    assert_receive {:metric, [:exiron, :hub, :delivery, :rejected], %{count: 1},
                    %{hook: "assistant", reason: :unavailable}}

    assert {:ok, []} = Hub.poll("ai-token")
    :ok = Hub.incoming_service_message(message)

    assert_receive {:metric, [:exiron, :hub, :queue], %{count: 1, bytes: bytes},
                    %{hook: "assistant"}}

    assert bytes > 0
    assert_receive {:metric, [:exiron, :hub, :pending], %{count: 1}, %{}}
    assert {:ok, [request]} = Hub.poll("ai-token")
    assert :ok = Hub.respond("ai-token", request.req_id, "text", "reply")
    assert_receive {:metric, [:exiron, :hub, :sends], %{count: 1}, %{}}

    assert_receive {:metric, [:exiron, :hub, :send, :stop], %{duration: duration},
                    %{kind: :respond, outcome: :ok}}

    assert duration >= 0

    assert_receive {:metric, [:exiron, :hub, :response, :stop], %{duration: response_duration},
                    %{hook: "assistant"}}

    assert response_duration >= duration
    assert Hub.status().delivery_health.in_flight_sends == 0
  end

  test "background timeouts count as failed operations and stale completion cannot double count",
       %{router: router} do
    alias Exiron.Hub.{SendCommand, SendTask, SendTasks}
    ref = make_ref()

    command =
      SendCommand.background(:unavailable, "assistant", Message.new(222, 123, "text", "offline"))

    task = %SendTask{
      command: command,
      pid: self(),
      monitor: make_ref(),
      started_at: System.monotonic_time()
    }

    state =
      %State{enabled?: true, router: router}
      |> put_in([Access.key!(:delivery), Access.key!(:sends), ref], task)

    transition = SendTasks.expire(state, ref)
    assert transition.next_state.health["assistant"].send_failures == 1
    assert transition.next_state.delivery.sends == %{}
    assert Enum.any?(transition.effects, &(&1.kind == :broadcast_status))
    stale = SendTasks.finish(transition.next_state, ref, :ok)
    assert stale.next_state == transition.next_state
  end
end
