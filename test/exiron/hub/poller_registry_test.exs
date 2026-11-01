defmodule Exiron.Hub.PollerRegistryTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.PollerRegistry

  test "tracks, replaces, and removes pollers by their monitor identity" do
    first = self()

    second =
      start_supervised!(
        {Task, fn -> receive do: (:stop -> :ok) end},
        id: make_ref(),
        restart: :temporary
      )

    state = PollerRegistry.track(%State{}, "token", first)
    %{monitor: first_monitor} = state.telegram_pollers["token"]

    assert PollerRegistry.track(state, "token", first) == state

    state = PollerRegistry.track(state, "token", second)
    %{pid: ^second, monitor: second_monitor} = state.telegram_pollers["token"]
    refute second_monitor == first_monitor

    assert {:unchanged, ^state} = PollerRegistry.remove_down(state, first_monitor, first)
    assert {:removed, removed} = PollerRegistry.remove_down(state, second_monitor, second)
    assert removed.telegram_pollers == %{}
  end

  test "only the registered process can explicitly untrack a token" do
    state = PollerRegistry.track(%State{}, "token", self())
    other = start_supervised!({Task, fn -> :ok end}, id: make_ref(), restart: :temporary)
    assert PollerRegistry.untrack(state, "token", other) == state
    assert PollerRegistry.untrack(state, "token", self()).telegram_pollers == %{}
  end
end
