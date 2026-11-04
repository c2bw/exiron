defmodule Exiron.Hub.EventLog do
  @moduledoc false

  alias Exiron.Hub.{EventImage, EventMediaStore, History, Message}

  @max_events 100

  def record(state, direction, target, hook, %Message{} = message, kind, event_id) do
    media_store = media_store(state)

    event =
      event_payload(
        direction,
        target,
        hook,
        message,
        kind,
        event_id,
        state.settings.max_event_image_preview_bytes,
        state.settings.max_event_image_history_bytes,
        media_store
      )

    events = History.prepend(state.activity.events, event, @max_events)
    release_removed_media(state.activity.events, events, media_store)
    %{state | activity: %{state.activity | events: events}}
  end

  def enforce_limits(state) do
    events = Enum.take(state.activity.events, @max_events)
    release_removed_media(state.activity.events, events, media_store(state))

    %{state | activity: %{state.activity | events: events}}
  end

  def clear_media(state) do
    _result = EventMediaStore.clear(media_store(state))
    :ok
  end

  defp event_payload(
         direction,
         target,
         hook,
         message,
         kind,
         event_id,
         max_preview_bytes,
         max_history_bytes,
         media_store
       ) do
    %{
      id: event_id,
      at: DateTime.utc_now(),
      direction: direction,
      target: target,
      hook: hook,
      kind: kind,
      service_id: message.service_id,
      chat_id: message.chat_id,
      bot_name: message.bot_name,
      datatype: message.datatype,
      preview: preview(message),
      image_src:
        EventImage.source(
          message,
          max_preview_bytes,
          max_history_bytes,
          store: media_store,
          scope: media_scope(hook)
        ),
      sticker_id: sticker_id(message),
      file_unique_id: message.file_unique_id,
      sticker_emoji: message.sticker_emoji,
      emoji_list: Message.emoji_list(message.sticker_emoji),
      message_id: message.message_id,
      reply_to_message_id: message.reply_to_message_id
    }
  end

  def preview(%Message{datatype: "text", data: data}) do
    if String.valid?(data) do
      String.slice(data, 0, 160)
    else
      payload_description("text", data)
    end
  end

  def preview(%Message{datatype: datatype, data: data}),
    do: payload_description(datatype, data)

  defp media_scope(hook) when is_binary(hook), do: {:hook, hook}
  defp media_scope(_hook), do: nil

  def sticker_id(%Message{sticker_id: sticker_id}) when is_binary(sticker_id), do: sticker_id
  def sticker_id(%Message{datatype: "sticker", data: data}), do: data
  def sticker_id(_message), do: nil

  defp payload_description(datatype, data),
    do: "#{datatype} payload, #{byte_size(data)} bytes"

  defp release_removed_media(previous_events, retained_events, store) do
    retained_sources = MapSet.new(retained_events, &Map.get(&1, :image_src))

    Enum.each(previous_events, fn event ->
      source = Map.get(event, :image_src)

      unless MapSet.member?(retained_sources, source) do
        EventImage.delete_source(store, source)
      end
    end)
  end

  defp media_store(state), do: Map.get(state, :event_media_store, EventMediaStore)
end
