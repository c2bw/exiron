defmodule Exiron.Hub.Delivery do
  @moduledoc false

  alias Exiron.Hub.{Identifier, QueueBuffer}

  @type t :: %__MODULE__{
          ref: String.t(),
          items: [term()],
          count: non_neg_integer(),
          bytes: non_neg_integer()
        }

  defstruct ref: nil, items: [], count: 0, bytes: 0

  @spec new([term()]) :: t()
  def new(items) when is_list(items) do
    %__MODULE__{
      ref: Identifier.new(),
      items: items,
      count: length(items),
      bytes: QueueBuffer.bytes(items)
    }
  end

  def usage(%{socket_delivery: %__MODULE__{count: count, bytes: bytes}}), do: {count, bytes}
  def usage(%{http_delivery: %__MODULE__{count: count, bytes: bytes}}), do: {count, bytes}
  def usage(_client), do: {0, 0}
end
