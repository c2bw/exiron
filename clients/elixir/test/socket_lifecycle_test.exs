defmodule ExironClient.SocketLifecycleTest do
  use ExUnit.Case, async: true

  alias ExironClient.{SocketLifecycle, SocketState}

  test "models the complete connection lifecycle" do
    state = %SocketState{}

    assert SocketLifecycle.states() == [:disconnected, :connecting, :connected, :paused, :closing]
    assert {:ok, state} = SocketLifecycle.transition(state, :connect)
    assert state.connection_state == :connecting

    assert {:ok, state} = SocketLifecycle.transition(state, {:transport_connected, :socket})
    assert state.connection_state == :connecting
    assert state.conn == :socket

    assert {:ok, state} = SocketLifecycle.transition(state, :server_connected)
    assert state.connection_state == :connected
    assert state.connected?

    assert {:ok, state} = SocketLifecycle.transition(state, :pause)
    assert state.connection_state == :paused
    assert state.socket_paused?

    assert {:ok, state} = SocketLifecycle.transition(state, :resume)
    assert state.connection_state == :connected
    refute state.socket_paused?

    assert {:ok, state} = SocketLifecycle.transition(state, {:disconnect, :closed})
    assert state.connection_state == :disconnected
    refute state.connected?

    assert {:ok, state} = SocketLifecycle.transition(state, :close)
    assert state.connection_state == :closing
    assert {:ok, state} = SocketLifecycle.transition(state, :closed)
    assert state.connection_state == :disconnected
    assert state.conn == nil
  end

  test "rejects resuming a connection that was not paused" do
    assert {:error, {:invalid_transition, :disconnected, :resume}} =
             SocketLifecycle.transition(%SocketState{}, :resume)
  end
end
