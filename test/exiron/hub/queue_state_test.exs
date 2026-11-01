defmodule Exiron.Hub.QueueStateTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{
    ActivityState,
    ClientState,
    DeliveryState,
    Message,
    QueueBuffer,
    QueueState,
    Settings,
    State
  }

  import Exiron.Support.RouterHelper

  setup do
    %{router: load_router!("queue-state")}
  end

  test "hook availability follows live client or claimed pending request", %{router: router} do
    timer = Process.send_after(self(), :expiry, 10_000)

    live_state =
      router
      |> base_state()
      |> ClientState.put("assistant", "worker", false, make_ref(), timer)

    assert QueueState.hook_available?(live_state, "assistant")

    claimed_state =
      router
      |> base_state()
      |> put_in(
        [Access.key!(:delivery), Access.key!(:pending)],
        %{"request" => %{hook: "assistant", claimed?: true}}
      )

    assert QueueState.hook_available?(claimed_state, "assistant")

    idle_state =
      router
      |> base_state()
      |> put_in(
        [Access.key!(:delivery), Access.key!(:pending)],
        %{"request" => %{hook: "assistant", claimed?: false}}
      )

    refute QueueState.hook_available?(idle_state, "assistant")

    Process.cancel_timer(timer)
  end

  test "listener enqueueing only queues messages for allowed routes", %{router: router} do
    timer = Process.send_after(self(), :expiry, 10_000)

    state =
      router
      |> base_state()
      |> ClientState.put("assistant", "listener", true, make_ref(), timer)

    message = Message.new(222, 123, "text", "/ai hello", "bot-token", bot_name: "assistant-bot")

    {state, events} = QueueState.enqueue_listener_messages(state, message)

    assert [%{msgtype: "listen", instance: "assistant-bot"}] =
             QueueBuffer.items(state.delivery.queues["assistant"])

    assert [%{kind: "listen", hook: "assistant", message: ^message}] = events

    {state, events} =
      QueueState.enqueue_listener_messages(state, Message.new(222, 999, "text", "/ai nope"))

    assert state.delivery.queues["assistant"].count == 1
    assert events == []

    Process.cancel_timer(timer)
  end

  test "listener enqueueing skips routed hooks", %{router: router} do
    timer = Process.send_after(self(), :expiry, 10_000)

    state =
      router
      |> base_state()
      |> ClientState.put("assistant", "listener", true, make_ref(), timer)

    message = Message.new(222, 123, "text", "/ai hello", "bot-token", bot_name: "assistant-bot")

    {state, events} = QueueState.enqueue_listener_messages(state, message, ["assistant"])

    assert QueueBuffer.items(state.delivery.queues["assistant"]) == []
    assert events == []

    Process.cancel_timer(timer)
  end

  test "listener enqueueing includes routed hooks for listen all mode", %{router: router} do
    timer = Process.send_after(self(), :expiry, 10_000)

    state =
      router
      |> base_state()
      |> ClientState.put("assistant", "listener", :all, make_ref(), timer)

    message = Message.new(222, 123, "text", "/ai hello", "bot-token", bot_name: "assistant-bot")

    {state, events} = QueueState.enqueue_listener_messages(state, message, ["assistant"])

    assert [%{msgtype: "listen", instance: "assistant-bot"}] =
             QueueBuffer.items(state.delivery.queues["assistant"])

    assert [%{kind: "listen", hook: "assistant", message: ^message}] = events

    Process.cancel_timer(timer)
  end

  test "listener enqueueing drops oldest messages when the hook queue is full", %{router: router} do
    timer = Process.send_after(self(), :expiry, 10_000)

    state =
      router
      |> base_state()
      |> put_in([Access.key!(:settings), Access.key!(:max_queue_per_hook)], 2)
      |> ClientState.put("assistant", "listener", true, make_ref(), timer)

    {state, _events} =
      QueueState.enqueue_listener_messages(state, Message.new(222, 123, "text", "/ai one"))

    {state, _events} =
      QueueState.enqueue_listener_messages(state, Message.new(222, 123, "text", "/ai two"))

    {state, events} =
      QueueState.enqueue_listener_messages(state, Message.new(222, 123, "text", "/ai three"))

    {items, _state} = ClientState.drain_queue(state, "assistant")

    assert Enum.map(items, &Base.decode64!(&1.data)) == ["/ai two", "/ai three"]
    assert Enum.any?(events, &(&1.kind == "listen_dropped"))

    Process.cancel_timer(timer)
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
