defmodule ExironClient.SocketBackoffTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Error, SocketBackoff, SocketState}

  test "applies server retry hints without increasing exponential delay" do
    state = state(sleep: fn delay -> send(self(), {:slept, delay}) end)
    error = Error.new(:hook_already_connected, "busy", retry_after_ms: 75)

    assert {:ok, next} = SocketBackoff.reconnect_after(state, error)
    assert_received {:slept, 75}
    assert next.client.reconnect_backoff[:current_delay_ms] == 10
  end

  test "increases ordinary reconnect delay up to its configured maximum" do
    state = state(sleep: fn _delay -> :ok end)
    error = Error.new(:transport_error, "closed")

    assert {:ok, next} = SocketBackoff.reconnect_after(state, error)
    assert next.client.reconnect_backoff[:current_delay_ms] == 20
    assert SocketBackoff.reset(next).client.reconnect_backoff[:current_delay_ms] == 10
  end

  defp state(overrides) do
    backoff =
      [
        initial_delay_ms: 10,
        current_delay_ms: 10,
        max_delay_ms: 20,
        max_retry_time_ms: 1_000,
        sleep: fn _delay -> :ok end
      ]
      |> Keyword.merge(overrides)

    %SocketState{
      client: %{reconnect_backoff: backoff},
      connected?: true,
      last_error: :old,
      reconnect_started_at_ms: nil
    }
  end
end
