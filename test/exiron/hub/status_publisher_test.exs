defmodule Exiron.Hub.StatusPublisherTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.{ActivityState, Router, State, StatusPublisher}

  setup do
    # These tests publish local snapshots on the real PubSub topic. Freeze the
    # application Hub so completion of earlier background sends cannot interleave.
    :sys.suspend(Exiron.Hub)
    on_exit(fn -> :sys.resume(Exiron.Hub) end)
    :ok
  end

  test "initializes the published snapshot without broadcasting" do
    :ok = StatusPublisher.subscribe()
    state = enabled_state()

    initialized = StatusPublisher.initialize(state)

    assert initialized.publication.snapshot == StatusPublisher.snapshot(initialized)
    assert initialized.publication.revision == 0
    refute_receive {:hub_status, _snapshot}
  end

  test "publishes row-level deltas and advances the revision" do
    :ok = StatusPublisher.subscribe()

    state = enabled_state() |> StatusPublisher.initialize()
    event = %{id: "status-publisher-event", preview: "event"}

    published =
      StatusPublisher.publish(%{state | activity: %ActivityState{events: [event]}})

    assert_receive {:hub_status_delta,
                    %{
                      base_revision: 0,
                      revision: 1,
                      collections: %{
                        events: %{upserts: [%{at: 0, item: ^event}]}
                      }
                    }}

    assert published.publication.revision == 1
    assert published.publication.snapshot.revision == 1
    assert published.publication.snapshot == StatusPublisher.snapshot(published)
  end

  test "does not broadcast unchanged snapshots" do
    :ok = StatusPublisher.subscribe()
    state = enabled_state() |> StatusPublisher.initialize()

    assert StatusPublisher.publish(state) == state
    refute_receive {:hub_status_delta, _delta}
  end

  test "initial full publication matches a fresh snapshot and the next delta revision" do
    :ok = StatusPublisher.subscribe()
    state = StatusPublisher.publish(enabled_state())
    assert_receive {:hub_status, snapshot}
    assert snapshot == StatusPublisher.snapshot(state)
    assert snapshot.revision == 1

    next = StatusPublisher.publish(%{state | activity: %ActivityState{events: [%{id: "new"}]}})
    assert_receive {:hub_status_delta, %{base_revision: 1, revision: 2}}
    assert next.publication.snapshot == StatusPublisher.snapshot(next)
    assert StatusPublisher.publish(next) == next
    refute_receive {:hub_status_delta, _}
  end

  test "disabled publications preserve their public snapshot semantics" do
    :ok = StatusPublisher.subscribe()
    initial = StatusPublisher.publish(State.new())
    assert_receive {:hub_status, snapshot}
    assert snapshot == StatusPublisher.snapshot(initial)

    state = enabled_state() |> StatusPublisher.initialize()
    disabled = StatusPublisher.publish(%{state | enabled?: false})
    assert_receive {:hub_status_delta, %{values: %{enabled: false}}}
    assert disabled.publication.snapshot == StatusPublisher.snapshot(disabled)
    assert StatusPublisher.publish(disabled) == disabled
    refute_receive {:hub_status_delta, _}
  end

  defp enabled_state do
    State.new(enabled?: true, router: %Router{})
  end
end
