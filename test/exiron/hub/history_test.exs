defmodule Exiron.Hub.HistoryTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.History

  test "prepends an item and retains only the newest entries" do
    assert History.prepend([:third, :second, :first], :fourth, 3) == [
             :fourth,
             :third,
             :second
           ]
  end

  test "a zero limit retains no entries" do
    assert History.prepend([:existing], :new, 0) == []
  end
end
