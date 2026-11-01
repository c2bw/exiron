defmodule ExironClient.ReconnectPolicy do
  @moduledoc false

  alias ExironClient.Error

  def delay_ms(_backoff, %Error{retry_after_ms: retry_after_ms})
      when is_integer(retry_after_ms) and retry_after_ms > 0,
      do: retry_after_ms

  def delay_ms(backoff, _error) do
    base = min(Keyword.fetch!(backoff, :current_delay_ms), Keyword.fetch!(backoff, :max_delay_ms))

    if Keyword.get(backoff, :jitter, true) and base > 1 do
      half = div(base, 2)
      half + :rand.uniform(base - half + 1) - 1
    else
      base
    end
  end

  def retry_budget_available?(backoff, started_at_ms, delay_ms) do
    elapsed_ms = monotonic_ms() - started_at_ms
    elapsed_ms + delay_ms <= Keyword.fetch!(backoff, :max_retry_time_ms)
  end

  def next_backoff(backoff, %Error{} = error) do
    if Error.hook_already_connected?(error) do
      backoff
    else
      next_exponential_backoff(backoff)
    end
  end

  def sleep(backoff, delay_ms) do
    sleep = Keyword.fetch!(backoff, :sleep)

    case sleep.(delay_ms) do
      {:error, reason} -> {:error, sleep_error(reason)}
      _ok -> :ok
    end
  end

  def reset_client_backoff(%{reconnect_backoff: reconnect_backoff} = client) do
    initial_delay_ms = Keyword.fetch!(reconnect_backoff, :initial_delay_ms)

    %{
      client
      | reconnect_backoff: Keyword.put(reconnect_backoff, :current_delay_ms, initial_delay_ms)
    }
  end

  defp next_exponential_backoff(backoff) do
    current_delay_ms = Keyword.fetch!(backoff, :current_delay_ms)
    max_delay_ms = Keyword.fetch!(backoff, :max_delay_ms)

    Keyword.put(backoff, :current_delay_ms, min(current_delay_ms * 2, max_delay_ms))
  end

  defp sleep_error(%Error{} = error), do: error
  defp sleep_error(reason), do: Error.new(:request_error, "retry sleep failed", body: reason)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
