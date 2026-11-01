defmodule ExironClient.SocketBackoff do
  @moduledoc false

  alias ExironClient.{Error, ReconnectPolicy}

  def reconnect_after(state, error) do
    started_at_ms = state.reconnect_started_at_ms || monotonic_ms()
    backoff = state.client.reconnect_backoff
    delay_ms = ReconnectPolicy.delay_ms(backoff, error)

    if ReconnectPolicy.retry_budget_available?(backoff, started_at_ms, delay_ms) do
      ExironClient.RuntimeStatus.phase(state, :backing_off, delay_ms)

      case ReconnectPolicy.sleep(backoff, delay_ms) do
        {:error, reason} ->
          {:error, reason}

        _ok ->
          if ReconnectPolicy.retry_budget_available?(backoff, started_at_ms, 0),
            do: {:ok, retry_state(state, error, started_at_ms)},
            else: {:error, error}
      end
    else
      {:error, error}
    end
  end

  def delay_ms(state, error), do: ReconnectPolicy.delay_ms(state.client.reconnect_backoff, error)

  def reset(%{client: client} = state) do
    client = ReconnectPolicy.reset_client_backoff(client)
    %{state | client: client, reconnect_started_at_ms: nil}
  end

  defp retry_state(state, error, started_at_ms) do
    %{
      state
      | connected?: false,
        last_error: nil,
        reconnect_started_at_ms: started_at_ms,
        client: next_client(state.client, error)
    }
  end

  defp next_client(client, %Error{} = error) do
    if Error.hook_already_connected?(error) do
      client
    else
      update_in(client.reconnect_backoff, &ReconnectPolicy.next_backoff(&1, error))
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
