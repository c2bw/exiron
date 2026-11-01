Code.require_file("../../../benchmarks/support/binary_owners.ex", __DIR__)

defmodule Exiron.Benchmarks.BinaryOwnersTest do
  use ExUnit.Case, async: true
  alias Exiron.Benchmarks.BinaryOwners

  test "samples referenced sizes and process identity without binary contents" do
    parent = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           bytes = :crypto.strong_rand_bytes(1_048_576)
           send(parent, {:holding, self()})

           receive do
             :finish -> send(parent, {:size, byte_size(bytes)})
           end
         end}
      )

    assert_receive {:holding, ^pid}
    profile = BinaryOwners.snapshot([pid])
    assert profile.unique_referenced_bytes >= 1_048_576
    assert [%{pid: owner, largest_binary_bytes: largest}] = profile.top_owners
    assert owner == inspect(pid)
    assert largest >= 1_048_576

    assert Map.keys(hd(profile.top_owners)) |> Enum.sort() ==
             Enum.sort([
               :pid,
               :registered_name,
               :initial_call,
               :current_function,
               :process_bytes,
               :mailbox,
               :referenced_bytes,
               :binary_count,
               :largest_binary_bytes
             ])

    ref = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:size, 1_048_576}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert BinaryOwners.snapshot([pid]).top_owners == []
  end
end
