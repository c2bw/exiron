defmodule Exiron.Support.Eventually do
  @moduledoc false

  import ExUnit.Assertions

  @default_attempts 10
  @default_delay 10

  def assert_eventually(fun, opts \\ []) when is_function(fun, 0) do
    assert retry_assertion(fun, attempts(opts), delay(opts))
  end

  def refute_eventually(fun, opts \\ []) when is_function(fun, 0) do
    refute retry_predicate(fun, attempts(opts), delay(opts))
  end

  defp retry_assertion(_fun, 0, _delay), do: false

  defp retry_assertion(fun, attempts, delay) do
    fun.()
    true
  rescue
    ExUnit.AssertionError ->
      wait(delay)
      retry_assertion(fun, attempts - 1, delay)
  end

  defp retry_predicate(_fun, 0, _delay), do: false

  defp retry_predicate(fun, attempts, delay) do
    if fun.() do
      true
    else
      wait(delay)
      retry_predicate(fun, attempts - 1, delay)
    end
  end

  defp attempts(opts), do: Keyword.get(opts, :attempts, @default_attempts)
  defp delay(opts), do: Keyword.get(opts, :delay, @default_delay)

  defp wait(delay) do
    receive do
    after
      delay -> :ok
    end
  end
end
