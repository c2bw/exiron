defmodule ExironClient.ReconnectPolicyTest do
  use ExUnit.Case, async: true

  alias ExironClient.{Error, ReconnectPolicy}

  describe "delay_ms/2" do
    test "uses retry_after_ms when present" do
      error = Error.new(:hook_already_connected, "busy", retry_after_ms: 75)

      assert ReconnectPolicy.delay_ms(base_backoff(), error) == 75
    end

    test "uses configured current delay otherwise" do
      error = Error.new(:transport_error, "connection closed")

      assert ReconnectPolicy.delay_ms(base_backoff(), error) == 10
    end
  end

  describe "next_backoff/2" do
    test "does not increase delay for hook conflict errors" do
      error = Error.new(:hook_already_connected, "busy", retry_after_ms: 50)

      assert Keyword.fetch!(
               ReconnectPolicy.next_backoff(base_backoff(), error),
               :current_delay_ms
             ) == 10
    end

    test "doubles delay and respects max delay" do
      error = Error.new(:transport_error, "connection closed")

      assert Keyword.fetch!(
               ReconnectPolicy.next_backoff(base_backoff(), error),
               :current_delay_ms
             ) == 20

      capped_backoff = Keyword.put(base_backoff(), :max_delay_ms, 12)

      assert Keyword.fetch!(
               ReconnectPolicy.next_backoff(capped_backoff, error),
               :current_delay_ms
             ) == 12
    end
  end

  describe "retry budget and sleep" do
    test "checks retry budget with elapsed time" do
      assert ReconnectPolicy.retry_budget_available?(base_backoff(), monotonic_ms_minus(5), 10)

      assert not ReconnectPolicy.retry_budget_available?(
               base_backoff(),
               monotonic_ms_minus(1),
               15_000
             )
    end

    test "normalizes sleep errors" do
      sleep_error = Error.new(:request_error, "retry canceled")

      sleep_error_backoff =
        Keyword.put(base_backoff(), :sleep, fn 10 -> {:error, sleep_error} end)

      assert {:error, ^sleep_error} = ReconnectPolicy.sleep(sleep_error_backoff, 10)

      other_error_backoff = Keyword.put(base_backoff(), :sleep, fn 10 -> {:error, :bad} end)

      assert {:error, %Error{reason: :request_error, message: "retry sleep failed", body: :bad}} =
               ReconnectPolicy.sleep(other_error_backoff, 10)
    end
  end

  test "resets the client backoff to its initial delay" do
    client = %{reconnect_backoff: Keyword.put(base_backoff(), :current_delay_ms, 20)}

    assert Keyword.fetch!(
             ReconnectPolicy.reset_client_backoff(client).reconnect_backoff,
             :current_delay_ms
           ) ==
             10
  end

  defp monotonic_ms_minus(delta_ms), do: System.monotonic_time(:millisecond) - delta_ms

  defp base_backoff do
    [
      jitter: false,
      initial_delay_ms: 10,
      current_delay_ms: 10,
      max_delay_ms: 30,
      max_retry_time_ms: 1_000,
      sleep: fn _delay_ms -> :ok end
    ]
  end
end
