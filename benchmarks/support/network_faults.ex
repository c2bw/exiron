defmodule Exiron.Benchmarks.NetworkFaults do
  @moduledoc false

  # The generator handles responses serially per hook/chat. Keep only its
  # current failed response, not every message ever sent. Steady mode needs no
  # records; fault mode uses at most one entry per configured chat.
  def fail?(table, true, chat_id, number) when rem(number, 97) == 0 do
    case :ets.take(table, chat_id) do
      [{^chat_id, ^number}] ->
        false

      _previous ->
        :ets.insert(table, {chat_id, number})
        true
    end
  end

  def fail?(_table, _faults?, _chat_id, _number), do: false
end
