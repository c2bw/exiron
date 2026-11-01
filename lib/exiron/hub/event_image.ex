defmodule Exiron.Hub.EventImage do
  @moduledoc false

  alias Exiron.Hub.{EventMediaStore, Message}

  @media_path "/api/event-media/"

  def source(
        %Message{datatype: "image", data: data},
        max_preview_bytes,
        max_history_bytes
      )
      when is_binary(data) and is_integer(max_preview_bytes) and is_integer(max_history_bytes) do
    source(%Message{datatype: "image", data: data}, max_preview_bytes, max_history_bytes, [])
  end

  def source(_message, _max_preview_bytes, _max_history_bytes), do: nil

  def source(
        %Message{datatype: "image", data: data},
        max_preview_bytes,
        max_history_bytes,
        opts
      )
      when is_binary(data) and is_integer(max_preview_bytes) and is_integer(max_history_bytes) and
             is_list(opts) do
    mime_type = mime_type(data)
    store = Keyword.get(opts, :store, EventMediaStore)
    scope = Keyword.get(opts, :scope)

    if preview_allowed?(data, mime_type, max_preview_bytes, max_history_bytes) do
      case EventMediaStore.put(store, data, mime_type, scope) do
        {:ok, id} -> @media_path <> id
        _unavailable_or_too_large -> nil
      end
    end
  end

  def source(_message, _max_preview_bytes, _max_history_bytes, _opts), do: nil

  def mime_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"

  def mime_type(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>),
    do: "image/png"

  def mime_type(<<"GIF87a", _rest::binary>>), do: "image/gif"
  def mime_type(<<"GIF89a", _rest::binary>>), do: "image/gif"
  def mime_type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  def mime_type(_data), do: nil

  def delete_source(store, @media_path <> id), do: EventMediaStore.delete(store, id)
  def delete_source(_store, _source), do: :ok

  defp preview_allowed?(data, mime_type, max_preview_bytes, max_history_bytes) do
    is_binary(mime_type) and max_preview_bytes > 0 and max_history_bytes > 0 and
      byte_size(data) <= max_preview_bytes and byte_size(data) <= max_history_bytes
  end
end
