defmodule Exiron.Hub.EventLogTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ActivityState, EventLog, EventMediaStore, Message, Settings}

  test "media events retain full captions separately from the payload summary" do
    caption = "<b>Photo & file</b>\n" <> String.duplicate("long caption ", 30)

    for datatype <- ["image", "file"], direction <- ["incoming", "outgoing"] do
      message = Message.new(222, 123, datatype, "bytes", nil, caption: caption)
      state = EventLog.record(base_state(), direction, "telegram", nil, message, "received", "id")

      assert [event] = state.activity.events
      assert event.caption == caption
      assert event.preview == "#{datatype} payload, 5 bytes"
      assert [wire] = event |> List.wrap() |> Jason.encode!() |> Jason.decode!()
      assert wire["caption"] == caption
    end
  end

  test "text preview is truncated" do
    message = Message.new(222, 123, "text", String.duplicate("a", 200))

    state = EventLog.record(base_state(), "incoming", "telegram", nil, message, "received", "id")

    assert [%{preview: preview}] = state.activity.events
    assert preview == String.duplicate("a", 160)
  end

  test "invalid UTF-8 text uses a JSON-safe payload description" do
    message = Message.new(222, 123, "text", <<0xFF, 0xFE>>)

    state = EventLog.record(base_state(), "incoming", "telegram", nil, message, "received", "id")

    assert [%{preview: "text payload, 2 bytes"}] = state.activity.events
    assert {:ok, _json} = Jason.encode(state.activity.events)
  end

  test "binary payload preview describes datatype and size" do
    message = Message.new(222, 123, "file", <<1, 2, 3, 4>>)

    state = EventLog.record(base_state(), "incoming", "telegram", nil, message, "received", "id")

    assert [%{preview: "file payload, 4 bytes"}] = state.activity.events
  end

  test "sticker events expose the sticker id" do
    sticker_emoji = "\u{1F923}"

    emoji_list = [
      "\u{1F606}",
      "\u{1F923}",
      "\u{1F600}",
      "\u{1F602}",
      "\u{1F604}",
      "\u{1F603}",
      "\u{1F601}"
    ]

    message =
      Message.new(222, 123, "sticker", "sticker-file-id", nil, sticker_emoji: sticker_emoji)

    state = EventLog.record(base_state(), "outgoing", "telegram", nil, message, "push", "id")

    assert [
             %{
               sticker_id: "sticker-file-id",
               sticker_emoji: ^sticker_emoji,
               emoji_list: ^emoji_list
             }
           ] =
             state.activity.events
  end

  test "emoji lists include hardcoded emotion groups" do
    assert Message.emoji_list("\u{1F923}") == [
             "\u{1F606}",
             "\u{1F923}",
             "\u{1F600}",
             "\u{1F602}",
             "\u{1F604}",
             "\u{1F603}",
             "\u{1F601}"
           ]

    assert Message.emoji_list("\u{1F602}") == Message.emoji_list("\u{1F923}")

    assert Message.emoji_list("\u{1F62D}") == [
             "\u{1F622}",
             "\u{1F625}",
             "\u{1F62D}",
             "\u{1F61E}",
             "\u{1F641}",
             "\u{1F613}",
             "\u{1F61F}",
             "\u{1F614}"
           ]

    assert Message.emoji_list("\u{2764}\u{FE0F}") == [
             "\u{2764}\u{FE0F}",
             "\u{1F970}",
             "\u{1F60D}",
             "\u{1F618}",
             "\u{1F617}"
           ]

    assert Message.emoji_list("\u{1F621}") == [
             "\u{1F621}",
             "\u{1F620}",
             "\u{1F92C}",
             "\u{1F624}",
             "\u{1F612}"
           ]

    assert Message.emoji_list("unknown") == []
  end

  test "supported image payloads retain only opaque authenticated sources" do
    images = [
      {"image/jpeg", <<0xFF, 0xD8, 0xFF, "image bytes">>},
      {"image/png", png("image bytes")},
      {"image/gif", <<"GIF89a", "image bytes">>},
      {"image/webp", <<"RIFF", 0, 0, 0, 0, "WEBP", "image bytes">>}
    ]

    for {_mime_type, image} <- images do
      message = Message.new(222, 123, "image", image)

      state =
        EventLog.record(base_state(), "incoming", "telegram", nil, message, "received", "id")

      assert [%{image_src: image_src}] = state.activity.events
      assert "/api/event-media/" <> _id = image_src
      refute String.contains?(image_src, "base64")
    end
  end

  test "images larger than the per-preview limit keep metadata without a preview" do
    image = png("image bytes")
    message = Message.new(222, 123, "image", image)
    preview = "image payload, #{byte_size(image)} bytes"

    state =
      base_state()
      |> put_in(
        [Access.key!(:settings), Access.key!(:max_event_image_preview_bytes)],
        byte_size(image) - 1
      )
      |> EventLog.record("incoming", "telegram", nil, message, "received", "id")

    assert [%{image_src: nil, preview: ^preview}] = state.activity.events
  end

  test "recording events does not retain image bytes in the event state" do
    image = png("image bytes")
    message = Message.new(222, 123, "image", image)

    state =
      base_state()
      |> put_in(
        [Access.key!(:settings), Access.key!(:max_event_image_history_bytes)],
        byte_size(image)
      )
      |> EventLog.record("incoming", "telegram", nil, message, "received", "old")
      |> EventLog.record("incoming", "telegram", nil, message, "received", "new")

    assert [%{id: "new", image_src: new_src}, %{id: "old", image_src: old_src}] =
             state.activity.events

    assert String.starts_with?(new_src, "/api/event-media/")
    assert String.starts_with?(old_src, "/api/event-media/")
    refute Enum.any?(state.activity.events, &(Map.get(&1, :preview) =~ "base64"))
  end

  test "event retention keeps the newest event plus 99 previous entries" do
    state =
      put_in(
        base_state(),
        [Access.key!(:activity), Access.key!(:events)],
        Enum.map(1..100, &%{id: &1})
      )

    message = Message.new(222, 123, "text", "new")

    state = EventLog.record(state, "incoming", "telegram", nil, message, "received", "new")

    assert length(state.activity.events) == 100
    assert hd(state.activity.events).id == "new"
    assert List.last(state.activity.events).id == 99
  end

  test "event retention deletes media owned by an expired event" do
    name = :"event_log_store_#{System.unique_integer([:positive])}"
    store = start_supervised!({EventMediaStore, max_bytes: 100, name: name})
    assert {:ok, media_id} = EventMediaStore.put(store, "image", "image/png", nil)

    events =
      Enum.map(1..99, &%{id: &1, image_src: nil}) ++
        [%{id: 100, image_src: "/api/event-media/#{media_id}"}]

    state =
      base_state()
      |> put_in([Access.key!(:activity), Access.key!(:events)], events)
      |> Map.put(:event_media_store, store)

    message = Message.new(222, 123, "text", "new")

    _state = EventLog.record(state, "incoming", "telegram", nil, message, "received", "new")

    assert EventMediaStore.fetch(store, media_id, :dashboard) == {:error, :not_found}
  end

  defp base_state do
    %{
      activity: %ActivityState{},
      settings:
        Settings.from_options(
          max_event_image_preview_bytes: 8 * 1024 * 1024,
          max_event_image_history_bytes: 64 * 1024 * 1024
        )
    }
  end

  defp png(data), do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, data::binary>>
end
