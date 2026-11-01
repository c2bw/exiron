defmodule Exiron.Hub.StatusDeltaTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.StatusDelta

  test "exposes the canonical status collection registry" do
    assert StatusDelta.collection_keys() == [
             :hooks,
             :routes,
             :chats,
             :events,
             :send_failures,
             :overload_events,
             :membership_events,
             :bot_memberships,
             :client_events,
             :suppressed_bots
           ]
  end

  test "emits scalar and row-level collection changes" do
    previous = snapshot(%{requested: 0, hooks: [hook(false, 0)], events: [event("old")]})

    current =
      snapshot(%{
        requested: 1,
        hooks: [hook(true, 1)],
        events: [event("new"), event("old")]
      })

    assert {:changed, delta} = StatusDelta.between(previous, current)
    assert delta.values == %{requested: 1}
    assert delta.metrics == %{connected: 1, queued: 1}

    assert %{deletes: [], upserts: [%{at: 0, item: %{id: "new"}}]} =
             delta.collections.events

    assert %{deletes: [], upserts: [%{at: 0, item: %{connected: true, queued: 1}}]} =
             delta.collections.hooks
  end

  test "deletes evicted history rows without resetting retained rows" do
    previous = snapshot(%{events: [event("second"), event("first")]})
    current = snapshot(%{events: [event("third"), event("second")]})

    assert {:changed, %{collections: %{events: events}}} =
             StatusDelta.between(previous, current)

    assert [%{id: "first"}] = events.deletes
    assert [%{at: 0, item: %{id: "third"}}] = events.upserts
    refute Map.has_key?(events, :reset)
  end

  test "falls back to a reset when retained rows are reordered" do
    previous = snapshot(%{routes: [route("a"), route("b")]})
    current = snapshot(%{routes: [route("b"), route("a")]})

    assert {:changed, %{collections: %{routes: %{reset: reset}}}} =
             StatusDelta.between(previous, current)

    assert Enum.map(reset, & &1.id) == ["b", "a"]
  end

  test "does not emit unchanged snapshots" do
    status = snapshot()
    assert :unchanged = StatusDelta.between(status, status)
  end

  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        enabled: true,
        requested: 0,
        hooks: [],
        routes: [],
        chats: [],
        events: [],
        send_failures: [],
        overload_events: [],
        membership_events: [],
        bot_memberships: [],
        client_events: [],
        revision: 0
      },
      overrides
    )
  end

  defp hook(connected, queued) do
    %{name: "assistant", connected: connected, listening: connected, queued: queued}
  end

  defp event(id), do: %{id: id, preview: id}
  defp route(id), do: %{id: id, to: id}
end
