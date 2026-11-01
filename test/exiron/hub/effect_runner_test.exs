defmodule Exiron.Hub.EffectRunnerTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{DeliveryState, Effect, EffectRunner, SendCommand, Settings, State, Transition}

  test "preserves the synchronous reply while delivering deferred replies" do
    tag = make_ref()

    transition =
      Transition.new(:next_state,
        reply: :synchronous,
        effects: [Effect.reply({self(), tag}, :deferred)]
      )

    assert {:next_state, :synchronous} = EffectRunner.run(transition)
    assert_receive {^tag, :deferred}
  end

  test "schedules and cancels timer effects" do
    timer = Process.send_after(self(), :cancelled_message, 60_000)

    transition =
      Transition.new(:state,
        effects: [
          Effect.cancel_timer(timer),
          Effect.schedule(:scheduled_message, 1)
        ]
      )

    assert {:state, nil} = EffectRunner.run(transition)
    assert Process.read_timer(timer) == false
    assert_receive :scheduled_message
    refute_received :cancelled_message
  end

  test "restores the failure state when send capacity is exhausted" do
    from = {self(), make_ref()}
    failure_state = State.new()

    state =
      State.new(
        settings: Settings.from_options(max_in_flight_sends: 1),
        delivery: %DeliveryState{sends: %{make_ref() => :occupied}}
      )

    effect =
      Effect.start_send(
        from,
        SendCommand.push(from, "assistant"),
        fn -> :ok end,
        failure_state
      )

    assert {^failure_state, {:error, :send_queue_full}} =
             EffectRunner.run(Transition.new(state, effects: [effect]))
  end

  test "background capacity rejection preserves tasks admitted earlier in the batch" do
    router = Exiron.HubCase.load_push_router!()
    occupied = %{make_ref() => %{command: %{hook: "assistant", payload_bytes: 0}}}

    before =
      State.new(router: router, settings: Settings.from_options(max_in_flight_sends_per_hook: 1))

    state = %{before | delivery: %DeliveryState{sends: occupied}}

    command =
      SendCommand.background(
        :overloaded,
        "assistant",
        Exiron.Hub.Message.new(222, 123, "text", "busy")
      )

    effect =
      Effect.start_send(nil, command, fn -> flunk("rejected sends must not start") end, before)

    assert {next, nil} = EffectRunner.run(Transition.new(state, effects: [effect]))
    assert next.delivery.sends == occupied
    assert next.health["assistant"].send_capacity_rejections == 1
    assert next.health["assistant"].send_failures == 0
  end

  test "deferred effects recheck byte capacity before starting a background worker" do
    router = Exiron.HubCase.load_push_router!()
    occupied = %{make_ref() => %{command: %{hook: "assistant", payload_bytes: 4}}}

    state =
      State.new(
        router: router,
        settings: Settings.from_options(max_in_flight_send_bytes: 4),
        delivery: %DeliveryState{sends: occupied}
      )

    command =
      SendCommand.background(
        :overloaded,
        "assistant",
        Exiron.Hub.Message.new(222, 123, "text", "busy")
      )

    effect =
      Effect.start_send(
        nil,
        command,
        fn -> flunk("byte rejection must happen before starting a worker") end,
        State.new()
      )

    assert {next, nil} = EffectRunner.run(Transition.new(state, effects: [effect]))
    assert next.delivery.sends == occupied
    assert next.delivery.send_byte_rejections == 1
    assert next.health["assistant"].send_byte_capacity_rejections == 1
  end
end
