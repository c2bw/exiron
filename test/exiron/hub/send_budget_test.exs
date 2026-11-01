defmodule Exiron.Hub.SendBudgetTest do
  use ExUnit.Case, async: true
  alias Exiron.Hub.{DeliveryState, SendBudget, SendCommand, SendTask, SendTasks, Settings, State}

  test "data and options are charged without depending on outgoing wire encoding" do
    data = <<0, 255, 2>>
    opts = [caption: String.duplicate("x", 100)]
    assert SendBudget.payload_bytes(data, opts) == byte_size(data) + :erlang.external_size(opts)
    assert SendBudget.payload_bytes(data, opts) > SendBudget.payload_bytes(data, [])
  end

  test "equality, per-hook isolation and global limit work independently of count limits" do
    state = %State{
      settings:
        Settings.from_options(max_in_flight_send_bytes: 10, max_in_flight_send_bytes_per_hook: 6),
      delivery: %DeliveryState{
        sends: %{make_ref() => %SendTask{command: %SendCommand{hook: "a", payload_bytes: 4}}}
      }
    }

    assert SendBudget.usage(state) == 4
    assert SendBudget.usage(state, "b") == 0
    assert SendTasks.ensure_capacity(state, "a", 2) == :ok
    assert SendTasks.ensure_capacity(state, "a", 3) == {:error, :hook_send_queue_full}
    assert SendTasks.ensure_capacity(state, "b", 6) == :ok
    assert SendTasks.ensure_capacity(state, "b", 7) == {:error, :send_queue_full}
    assert SendBudget.hook_limit(put_in(state.settings.max_in_flight_send_bytes, 3)) == 3
  end
end
