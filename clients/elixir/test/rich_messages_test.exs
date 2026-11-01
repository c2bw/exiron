defmodule ExironClient.RichMessagesTest do
  use ExUnit.Case, async: true
  alias ExironClient.{MediaItem, Message, Error}

  setup do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn req ->
            send(parent, {:request, req.url.path, Jason.decode!(req.body)})
            {req, Req.Response.json(%{ok: true})}
          end
        ]
      )

    %{client: client}
  end

  test "one-shot remains unchanged and streaming is a separate opt-in operation", %{
    client: client
  } do
    assert {:ok, _} = ExironClient.reply_text(client, "request", "one-shot")
    assert_receive {:request, "/api/responses", %{"data" => "b25lLXNob3Q="} = body}
    refute Map.has_key?(body, "final")

    assert {:ok, _} =
             ExironClient.stream_text(client, "request", ["Hel", "lo"], interval_ms: 100_000)

    assert_receive {:request, "/api/responses",
                    %{"final" => false, "data" => "SGVs", "parse_mode" => "plain"}}

    assert_receive {:request, "/api/responses",
                    %{"final" => true, "data" => "SGVsbG8=", "parse_mode" => "plain"}}

    refute_receive {:request, _, _}
  end

  test "typing, editing and metadata are explicit additions", %{client: client} do
    assert {:ok, _} = ExironClient.typing(client, %Message{req_id: "request"})
    assert_receive {:request, "/api/actions", %{"req_id" => "request", "action" => "typing"}}
    assert {:ok, _} = ExironClient.edit_text(client, "request", "fixed")
    assert_receive {:request, "/api/edits", %{"req_id" => "request", "data" => "Zml4ZWQ="}}

    assert {:ok, _} =
             ExironClient.push(client, 123, "file", "bytes",
               message_thread_id: 7,
               caption: "report",
               file_name: "report.pdf",
               mime_type: "application/pdf"
             )

    assert_receive {:request, "/api/push",
                    %{
                      "message_thread_id" => 7,
                      "caption" => "report",
                      "file_name" => "report.pdf"
                    }}
  end

  test "album helpers and decoding preserve member bytes and metadata", %{client: client} do
    items = [
      %MediaItem{datatype: "image", data: "one", caption: "Photos", file_name: "one.jpg"},
      %MediaItem{datatype: "video", data: "two", mime_type: "video/mp4"}
    ]

    assert {:ok, encoded} = MediaItem.encode(items)
    assert {:ok, ^items} = MediaItem.decode(encoded)

    assert {:ok, message} =
             Message.from_server(
               %{
                 "datatype" => "album",
                 "data" => Base.encode64(encoded),
                 "message_thread_id" => 7,
                 "caption" => "Photos"
               },
               :request
             )

    assert message.media_items == items
    assert message.message_thread_id == 7

    assert {:ok, _} = ExironClient.reply_album(client, "request", items)
    assert_receive {:request, "/api/responses", %{"datatype" => "album", "data" => data}}
    assert Base.decode64!(data) == encoded
    assert {:ok, _} = ExironClient.push_album_to_chat(client, 123, items, message_thread_id: 7)

    assert_receive {:request, "/api/push",
                    %{"datatype" => "album", "chat_id" => 123, "message_thread_id" => 7}}

    assert {:error, %Error{}} = MediaItem.encode([])
    assert {:error, %Error{}} = MediaItem.decode("invalid")
  end

  test "both metadata and album members decode from the shared contract fixture" do
    payload = ExironClient.FixtureHelpers.contract_json("requests_rich_response.json")

    assert {:ok, [album, text]} =
             ExironClient.Wire.Message.decode_list(payload["requests"], :request)

    assert album.message_thread_id == 7
    assert album.media_group_id == "album-1"

    assert [%MediaItem{data: "photo-one", file_name: "one.jpg"}, %MediaItem{data: "video-two"}] =
             album.media_items

    assert text.entities == [%{"type" => "bot_command", "offset" => 0, "length" => 3}]
  end

  test "stream errors stop immediately without finalizing or retrying" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            send(parent, :attempt)

            {request,
             Req.Response.json(
               %Req.Response{status: 504},
               %{code: "telegram_delivery_timeout", error: "telegram delivery result timed out"}
             )}
          end
        ]
      )

    assert {:error, %Error{status: 504}} =
             ExironClient.stream_text(client, "request", ["one", "two"])

    assert_receive :attempt
    refute_receive :attempt
    assert {:error, %Error{}} = ExironClient.stream_text(client, "request", [])
  end
end
