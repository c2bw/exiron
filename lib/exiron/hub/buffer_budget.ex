defmodule Exiron.Hub.BufferBudget do
  @moduledoc false
  alias Exiron.Hub.{Delivery, QueueBuffer}

  # Derive usage from retained buffers, avoiding a second mutable byte ledger
  # across acknowledgement, cancellation, expiry, reconnect and route reload.
  def snapshot(state) do
    queued =
      Enum.reduce(state.delivery.queues, 0, fn {_hook, queue}, total ->
        total + QueueBuffer.bytes(queue)
      end)

    awaiting_ack =
      Enum.reduce(state.delivery.clients, 0, fn {_hook, client}, total ->
        Enum.reduce([:socket_delivery, :http_delivery], total, fn key, acc ->
          case Map.get(client, key) do
            %Delivery{bytes: bytes} -> acc + bytes
            _ -> acc
          end
        end)
      end)

    %{
      bytes: queued + awaiting_ack,
      queued_bytes: queued,
      awaiting_ack_bytes: awaiting_ack,
      limit: state.settings.max_buffered_bytes,
      request_rejections: state.delivery.buffer_rejections.requests,
      listener_rejections: state.delivery.buffer_rejections.listeners
    }
  end

  def available?(state, bytes) do
    snapshot = snapshot(state)
    snapshot.bytes + bytes <= snapshot.limit
  end

  def reject(state, kind) when kind in [:requests, :listeners] do
    update_in(state.delivery.buffer_rejections[kind], &(&1 + 1))
  end
end
