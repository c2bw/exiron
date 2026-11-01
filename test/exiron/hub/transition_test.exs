defmodule Exiron.Hub.TransitionTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Effect, Transition}

  test "preserves next state, reply, and effect order" do
    state = %{counter: 1}

    transition =
      state
      |> Transition.new(reply: :ok)
      |> Transition.effect(Effect.cancel_timer(:timer))
      |> Transition.effect(Effect.broadcast_status())

    assert %Transition{
             next_state: ^state,
             reply: :ok,
             effects: [
               %Effect{kind: :cancel_timer, payload: :timer},
               %Effect{kind: :broadcast_status}
             ]
           } = transition
  end

  test "prepends an effect without changing later ordering" do
    transition =
      Transition.new(:state, effects: [Effect.broadcast_status()])
      |> Transition.prepend_effect(Effect.cancel_timer(:timer))

    assert [%Effect{kind: :cancel_timer}, %Effect{kind: :broadcast_status}] =
             transition.effects
  end
end
