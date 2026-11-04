defmodule Exiron.Hub.Telegram.MessageParserTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Telegram.MessageParser

  test "prefers text and falls back to captions" do
    assert {:ok, "text", "hello"} = MessageParser.content(%{text: "hello", caption: "ignored"})
    assert {:ok, "text", "caption"} = MessageParser.content(%{text: "", caption: "caption"})
    assert :ignore = MessageParser.content(%{caption: ""})
    assert :ignore = MessageParser.content(%{})
  end

  test "maps every Telegram file shape to the wire datatype" do
    fixtures = [
      {%{audio: %{file_id: "audio"}}, "audio", "audio"},
      {%{voice: %{file_id: "voice"}}, "voice", "audio"},
      {%{video: %{file_id: "video"}}, "video", "video"},
      {%{video_note: %{file_id: "note"}}, "note", "video"},
      {%{photo: [%{file_id: "small"}, %{file_id: "large"}]}, "large", "image"},
      {%{document: %{file_id: "document"}}, "document", "file"},
      {%{animation: %{file_id: "animation"}}, "animation", "file"}
    ]

    for {message, file_id, datatype} <- fixtures do
      assert {:file, ^file_id, ^datatype, %{}} = MessageParser.content(message)
    end
  end

  test "preserves sticker identity and optional emoji" do
    assert {:file, "sticker", "file",
            %{sticker_id: "sticker", file_unique_id: "unique", sticker_emoji: "🙂"}} =
             MessageParser.content(%{
               sticker: %{file_id: "sticker", file_unique_id: "unique", emoji: "🙂"}
             })

    assert {:file, "no-emoji", "file", %{sticker_id: "no-emoji", file_unique_id: "unique"}} =
             MessageParser.content(%{sticker: %{file_id: "no-emoji", file_unique_id: "unique"}})

    assert {:file, "plain", "file", %{sticker_id: "plain", file_unique_id: nil}} =
             MessageParser.content(%{sticker: %{file_id: "plain", emoji: ""}})
  end

  test "extracts bounded sender and reply metadata" do
    message = %{
      message_id: 12,
      reply_to_message: %{message_id: 11},
      from: %{
        id: 42,
        is_bot: false,
        first_name: "Ada",
        last_name: "Lovelace",
        username: "ada",
        language_code: "en",
        ignored: "value"
      }
    }

    assert %{
             message_id: 12,
             reply_to_message_id: 11,
             from: %{id: 42, first_name: "Ada", username: "ada"}
           } = MessageParser.metadata(message)

    assert %{message_id: nil, reply_to_message_id: nil, from: nil} =
             MessageParser.metadata(%{
               message_id: "invalid",
               reply_to_message: %{message_id: nil}
             })
  end
end
