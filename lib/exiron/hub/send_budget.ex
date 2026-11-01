defmodule Exiron.Hub.SendBudget do
  @moduledoc false

  # Count retained source payload and client options without encoding/copying it.
  # Album data is the album JSON (including its member base64); network encoding
  # and temporary decoded buffers are outside this logical payload budget.
  def payload_bytes(data, opts), do: byte_size(data) + :erlang.external_size(opts)

  def usage(state) do
    Enum.reduce(state.delivery.sends, 0, fn
      {_, %{command: %{payload_bytes: bytes}}}, total -> total + bytes
      _, total -> total
    end)
  end

  def usage(state, hook),
    do:
      Enum.reduce(state.delivery.sends, 0, fn
        {_, %{command: %{hook: ^hook, payload_bytes: bytes}}}, total -> total + bytes
        _, total -> total
      end)

  def hook_limit(state),
    do:
      min(
        state.settings.max_in_flight_send_bytes,
        state.settings.max_in_flight_send_bytes_per_hook
      )

  def exceeded?(state, hook, bytes),
    do:
      usage(state) + bytes > state.settings.max_in_flight_send_bytes or
        usage(state, hook) + bytes > hook_limit(state)

  def snapshot(state),
    do: %{
      bytes: usage(state),
      limit: state.settings.max_in_flight_send_bytes,
      rejections: state.delivery.send_byte_rejections
    }

  def reject(state, hook) do
    state = update_in(state.delivery.send_byte_rejections, &(&1 + 1))
    Exiron.Hub.DeliveryHealth.send_bytes_rejected(state, hook)
  end
end
