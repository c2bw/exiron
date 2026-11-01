defmodule Exiron.Hub.History do
  @moduledoc """
  Maintains bounded, newest-first runtime histories.

  Hub histories are exposed by the status API, so their order and limits are
  part of the runtime data shape even though the entries live only in memory.
  """

  @spec prepend([item], item, non_neg_integer()) :: [item] when item: var
  def prepend(_items, _item, 0), do: []

  def prepend(items, item, limit) when is_list(items) and is_integer(limit) and limit > 0 do
    [item | Enum.take(items, limit - 1)]
  end
end
