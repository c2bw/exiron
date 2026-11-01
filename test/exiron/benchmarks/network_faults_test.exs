Code.require_file("../../../benchmarks/support/network_faults.ex", __DIR__)

defmodule Exiron.Benchmarks.NetworkFaultsTest do
  use ExUnit.Case, async: true
  alias Exiron.Benchmarks.NetworkFaults

  test "steady sends retain no attempt records" do
    table = :ets.new(:attempts, [:set, :public])
    for number <- 1..10000, do: refute(NetworkFaults.fail?(table, false, rem(number, 24), number))
    assert :ets.info(table, :size) == 0
  end

  test "fault tracking fails once per current serial response and is bounded by chat count" do
    table = :ets.new(:attempts, [:set, :public])

    for chat <- 1..24 do
      assert NetworkFaults.fail?(table, true, chat, 97)
      refute NetworkFaults.fail?(table, true, chat, 97)
      refute NetworkFaults.fail?(table, true, chat, 98)
    end

    assert :ets.info(table, :size) == 0

    for number <- 1..1000, chat <- 1..24 do
      assert NetworkFaults.fail?(table, true, chat, number * 97)
    end

    assert :ets.info(table, :size) == 24
  end
end
