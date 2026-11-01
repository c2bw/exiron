defmodule Exiron.Hub.QueueBuffer do
  @moduledoc false

  alias Exiron.Hub.Message

  @type t :: %__MODULE__{
          items: [term()],
          count: non_neg_integer(),
          bytes: non_neg_integer()
        }

  defstruct items: [], count: 0, bytes: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec from_items([term()]) :: t()
  def from_items(items) when is_list(items), do: build(items)

  @spec push(t(), term(), {non_neg_integer(), non_neg_integer()}) ::
          {t(), non_neg_integer()}
  def push(%__MODULE__{} = buffer, item, {max_count, max_bytes}),
    do: push_buffer(buffer, item, max_count, max_bytes)

  @spec drain(t()) :: {[term()], t()}
  def drain(%__MODULE__{items: items}), do: {Enum.reverse(items), new()}

  @spec prepend(t(), [term()]) :: t()
  def prepend(%__MODULE__{} = buffer, items) when is_list(items) do
    added = Enum.reverse(items)
    build(buffer.items ++ added)
  end

  @spec remove(t(), (term() -> as_boolean(term()))) :: t()
  def remove(%__MODULE__{} = buffer, predicate) do
    buffer
    |> Map.update!(:items, fn items -> Enum.reject(items, predicate) end)
    |> refresh()
  end

  @spec items(t()) :: [term()]
  def items(%__MODULE__{items: items}), do: items

  def bytes(%__MODULE__{bytes: bytes}), do: bytes
  def bytes(items) when is_list(items), do: build(items).bytes

  defp push_buffer(buffer, item, max_count, max_bytes) do
    candidate = build([item | buffer.items])
    bounded = trim(candidate, max_count, max_bytes)
    {bounded, candidate.count - bounded.count}
  end

  defp trim(buffer, max_count, max_bytes) do
    buffer
    |> Map.update!(:items, &Enum.take(&1, max_count))
    |> refresh()
    |> trim_bytes(max_bytes)
  end

  defp trim_bytes(buffer, max_bytes) when buffer.bytes <= max_bytes, do: buffer

  defp trim_bytes(%__MODULE__{items: []} = buffer, _max_bytes), do: buffer

  defp trim_bytes(%__MODULE__{items: items} = buffer, max_bytes) do
    {_oldest, remaining} = List.pop_at(items, -1)
    trim_bytes(%{buffer | items: remaining} |> refresh(), max_bytes)
  end

  defp build(items) do
    %__MODULE__{items: items, count: length(items), bytes: bytes_for(items)}
  end

  defp refresh(%__MODULE__{items: items}), do: build(items)

  defp bytes_for(items), do: Enum.reduce(items, 0, &(item_bytes(&1) + &2))

  defp item_bytes(%Message{} = message), do: Message.client_payload_size(message)
  defp item_bytes(%{data: data}) when is_binary(data), do: byte_size(data)
  defp item_bytes(_item), do: 0
end
