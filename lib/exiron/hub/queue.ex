defmodule Exiron.Hub.Queue do
  @moduledoc false

  alias Exiron.Hub.{BufferBudget, Delivery, Message, QueueBuffer}

  @type kind :: :routed | :listener

  @spec bounds(map(), String.t(), kind()) :: {non_neg_integer(), non_neg_integer()}
  def bounds(state, hook, kind) when kind in [:routed, :listener] do
    {delivery_count, delivery_bytes} = Delivery.usage(Map.get(state.delivery.clients, hook))

    {
      max(state.settings.max_queue_per_hook - delivery_count, 0),
      max(state.settings.max_queue_bytes_per_hook - delivery_bytes, 0)
    }
  end

  def routed_bounds(state, hook), do: bounds(state, hook, :routed)
  def listener_bounds(state, hook), do: bounds(state, hook, :listener)

  @spec usage(map(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  def usage(state, hook) do
    {delivery_count, delivery_bytes} = Delivery.usage(Map.get(state.delivery.clients, hook))
    queued = Map.get(state.delivery.queues, hook, QueueBuffer.new())

    {queued.count + delivery_count, queued.bytes + delivery_bytes}
  end

  @spec available?(map(), String.t(), Message.t()) :: :ok | {:error, atom()}
  def available?(state, hook, %Message{} = message) do
    {count, bytes} = usage(state, hook)

    cond do
      map_size(state.delivery.pending) >= state.settings.max_pending ->
        {:error, :max_pending}

      count >= state.settings.max_queue_per_hook ->
        {:error, :max_queue_per_hook}

      bytes + Message.queued_payload_size(message) > state.settings.max_queue_bytes_per_hook ->
        {:error, :max_queue_bytes_per_hook}

      not BufferBudget.available?(state, Message.queued_payload_size(message)) ->
        {:error, :max_buffered_bytes}

      true ->
        :ok
    end
  end

  def put(buffer, item, state, hook, kind),
    do: QueueBuffer.push(buffer, item, bounds(state, hook, kind))
end
