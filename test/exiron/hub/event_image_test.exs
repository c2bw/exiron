defmodule Exiron.Hub.EventImageTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{EventImage, EventMediaStore, Message}

  @max_bytes 8 * 1024 * 1024

  setup do
    name = :"event_image_store_#{System.unique_integer([:positive])}"
    start_supervised!({EventMediaStore, name: name, max_bytes: @max_bytes})
    {:ok, store: name}
  end

  test "stores supported images and returns an opaque media URL", %{store: store} do
    image = png("image bytes")
    message = Message.new(222, 123, "image", image)

    assert "/api/event-media/" <> id =
             EventImage.source(message, @max_bytes, @max_bytes,
               store: store,
               scope: {:hook, "assistant"}
             )

    refute String.contains?(id, "base64")

    assert {:ok, %{mime_type: "image/png", bytes: ^image}} =
             EventMediaStore.fetch(store, id, {:hook, "assistant"})
  end

  test "zero or exceeded limits disable image media", %{store: store} do
    image = png("image bytes")
    message = Message.new(222, 123, "image", image)

    assert EventImage.source(message, 0, @max_bytes, store: store) == nil
    assert EventImage.source(message, @max_bytes, byte_size(image) - 1, store: store) == nil
  end

  defp png(data), do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, data::binary>>
end
