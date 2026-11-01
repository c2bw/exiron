defmodule ExironClient.SocketLifecycle do
  @moduledoc """
  Explicit, side-effect-free socket lifecycle transitions.

  Callback invocation and I/O remain in the surrounding processes; this module
  makes the legal connection states and their transitions independently
  testable.
  """

  alias ExironClient.SocketState

  @states [:disconnected, :connecting, :connected, :paused, :closing]

  @type state :: :disconnected | :connecting | :connected | :paused | :closing

  @spec states() :: [state()]
  def states, do: @states

  @spec transition(SocketState.t(), atom() | tuple()) ::
          {:ok, SocketState.t()} | {:error, term()}
  def transition(state, :connect) do
    {:ok, Map.put(state, :connection_state, :connecting)}
  end

  def transition(state, {:transport_connected, conn}) do
    {:ok,
     state
     |> Map.merge(%{connection_state: :connecting, conn: conn, connected?: false})}
  end

  def transition(state, :server_connected) do
    if connection_state(state) in [:disconnected, :connecting, :connected] do
      {:ok, Map.merge(state, %{connection_state: :connected, connected?: true})}
    else
      {:error, {:invalid_transition, connection_state(state), :server_connected}}
    end
  end

  def transition(state, :pause) do
    if connection_state(state) == :connected do
      {:ok, Map.merge(state, %{connection_state: :paused, socket_paused?: true})}
    else
      {:error, {:invalid_transition, connection_state(state), :pause}}
    end
  end

  def transition(state, :resume) do
    if connection_state(state) == :paused do
      {:ok, Map.merge(state, %{connection_state: :connected, socket_paused?: false})}
    else
      {:error, {:invalid_transition, connection_state(state), :resume}}
    end
  end

  def transition(state, {:disconnect, _reason}) do
    {:ok, Map.merge(state, %{connection_state: :disconnected, connected?: false})}
  end

  def transition(state, :close) do
    {:ok, Map.merge(state, %{connection_state: :closing, connected?: false})}
  end

  def transition(state, :closed) do
    {:ok, Map.merge(state, %{connection_state: :disconnected, connected?: false, conn: nil})}
  end

  def transition(state, event),
    do: {:error, {:invalid_transition, connection_state(state), event}}

  @spec connection_state(SocketState.t()) :: state()
  def connection_state(%{connection_state: state}) when state in @states, do: state
end
