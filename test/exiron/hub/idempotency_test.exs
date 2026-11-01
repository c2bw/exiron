defmodule Exiron.Hub.IdempotencyTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.{Effect, Idempotency, State, Transition}

  test "completed receipts expire lazily and retention never exceeds 500" do
    state =
      Enum.reduce(1..501, State.new(), fn n, state ->
        {state, from} = reserve(state, "key-#{n}", n)
        {state, :ok} = Idempotency.finish(state, from, :ok)
        state
      end)

    assert map_size(state.idempotency.records) == 500
    assert length(state.idempotency.order) == 500
    assert state.idempotency.running == %{}

    state = %{
      state
      | idempotency: %{
          state.idempotency
          | records:
              Map.new(state.idempotency.records, fn {key, record} ->
                {key, %{record | expires: System.monotonic_time(:millisecond) - 1}}
              end)
        }
    }

    {state, _} = reserve(state, "key-501", 501)
    assert map_size(state.idempotency.records) == 1
    assert map_size(state.idempotency.running) == 1
  end

  test "running entries cannot be evicted and completing one frees capacity" do
    state =
      Enum.reduce(1..500, State.new(), fn n, state -> elem(reserve(state, "key-#{n}", n), 0) end)

    transition =
      Idempotency.run(state, "hook", "new", {:push, "payload"}, {self(), make_ref()}, fn _ ->
        flunk("must reject before starting work")
      end)

    assert transition.reply == {:error, :idempotency_capacity_exceeded}
    assert map_size(transition.next_state.idempotency.running) == 500
    {from, _} = Enum.at(state.idempotency.running, 0)
    {state, :ok} = Idempotency.finish(state, from, :ok)
    {state, _} = reserve(state, "new", :new)
    assert map_size(state.idempotency.records) == 500
    assert map_size(state.idempotency.running) == 500
  end

  test "oversized results become a retained tombstone instead of being resent" do
    {state, from} = reserve(State.new(), "large", "private-payload")
    reply = {:ok, %{large: String.duplicate("x", 70_000)}}
    {state, ^reply} = Idempotency.finish(state, from, reply)

    duplicate =
      Idempotency.run(state, "hook", "large", "private-payload", {self(), make_ref()}, fn _ ->
        flunk("must not resend")
      end)

    assert duplicate.reply == {:error, :idempotency_result_unavailable}
    [record] = Map.values(state.idempotency.records)
    assert byte_size(record.result) < 65_536
    refute inspect(state.idempotency) =~ "private-payload"
    refute inspect(state.idempotency) =~ "large"
  end

  defp reserve(state, key, operation) do
    from = {self(), make_ref()}

    transition =
      Idempotency.run(state, "hook", key, operation, from, fn state ->
        Transition.new(state, effects: [%Effect{kind: :start_send, payload: %{from: from}}])
      end)

    {transition.next_state, from}
  end
end
