defmodule Exiron.Hub.CaptionDeliveryTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{MediaAlbum, Message, Telegram}
  alias Exiron.Hub.Telegram.{CaptionDelivery, TextSplitter}

  setup do
    parent = self()
    ids = start_supervised!({Agent, fn -> 900 end})

    sender = fn token, message ->
      send(parent, {:sent, token, message})

      if message.datatype == "album" do
        {:ok,
         Enum.map(message.media_items, fn _ ->
           %{message_id: Agent.get_and_update(ids, &{&1 + 1, &1 + 1})}
         end)}
      else
        {:ok, %{message_id: Agent.get_and_update(ids, &{&1 + 1, &1 + 1})}}
      end
    end

    :ok =
      Hub.configure(
        load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "default rejects oversized or malformed captions before any upload and permits correction" do
    for {opts, index} <-
          Enum.with_index([
            [caption: String.duplicate("a", 1025)],
            [caption: "<b>unclosed", parse_mode: "HTML", caption_overflow: true],
            [caption: "bad!", parse_mode: "MarkdownV2"],
            [caption: "<div>bad</div>", parse_mode: "HTML"]
          ]) do
      req = request(index + 10)

      assert {:error, :invalid_payload} =
               Hub.respond("ai-token", req.req_id, "image", "bytes", opts)

      refute_receive {:sent, _, _}
      assert :ok = Hub.respond("ai-token", req.req_id, "image", "bytes", caption: "corrected")
      assert_receive {:sent, _, %{datatype: "image", caption: "corrected"}}
    end
  end

  test "the UTF-16 boundary accepts 512 emoji and overflow preserves graphemes" do
    caption = String.duplicate("😀", 512)
    message = Message.new(222, 123, "image", "bytes", nil, caption: caption)
    assert {:ok, %{caption: ^caption}, []} = CaptionDelivery.prepare(message)

    assert {:error, :invalid_payload} =
             CaptionDelivery.prepare(%{message | caption: caption <> "😀"})

    assert {:ok, media, [{part, 0, true}]} =
             CaptionDelivery.prepare(%{
               message
               | caption: caption <> "😀",
                 caption_overflow?: true
             })

    assert media.caption == caption
    assert part.data == "😀"
  end

  test "formatting is balanced and explicit entities are clipped using rendered offsets" do
    text = String.duplicate("x", 1030)

    msg =
      Message.new(222, 123, "file", "bytes", nil,
        caption: "<b>" <> text <> "</b>",
        parse_mode: "HTML",
        caption_overflow: true
      )

    assert {:ok, media, [{part, _, _}]} = CaptionDelivery.prepare(msg)
    assert media.caption == "<b>" <> String.duplicate("x", 1024) <> "</b>"
    assert part.data == "<b>xxxxxx</b>"

    msg = %{
      msg
      | caption: text,
        parse_mode: "HTML",
        caption_entities: [%{type: "bold", offset: 1000, length: 30}]
    }

    assert {:ok, media, [{part, _, _}]} = CaptionDelivery.prepare(msg)
    assert media.caption_entities == [%{type: "bold", offset: 1000, length: 24}]
    assert part.entities == [%{type: "bold", offset: 0, length: 6}]
  end

  test "overflow follows media with original reply, topic and media-only buttons" do
    req = request()
    caption = String.duplicate("x", 1024 + 4096) <> "tail"

    assert :ok =
             Hub.respond("ai-token", req.req_id, "file", "bytes",
               caption: caption,
               caption_overflow: true,
               reply_to_original: true,
               inline_keyboard: [[%{text: "Next", callback_data: "next"}]]
             )

    assert_receive {:sent, "bot-token",
                    %{
                      datatype: "file",
                      caption: first,
                      reply_to_message_id: 10,
                      message_thread_id: 7,
                      inline_keyboard: [[_]]
                    }}

    assert_receive {:sent, "bot-token",
                    %{
                      datatype: "text",
                      data: second,
                      reply_to_message_id: 901,
                      message_thread_id: 7,
                      inline_keyboard: nil
                    }}

    assert_receive {:sent, "bot-token",
                    %{
                      datatype: "text",
                      data: "tail",
                      reply_to_message_id: nil,
                      message_thread_id: 7
                    }}

    assert first <> second <> "tail" == caption
    assert TextSplitter.units(first) == 1024
    assert TextSplitter.units(second) == 4096
  end

  test "all album captions are preflighted and overflow replies to the correct member" do
    items = [
      %{datatype: "image", data: "one", caption: String.duplicate("a", 1025)},
      %{datatype: "video", data: "two", caption: "<b>bad", parse_mode: "HTML"}
    ]

    req = request()

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "album", MediaAlbum.encode(items),
               caption_overflow: true
             )

    refute_receive {:sent, _, _}

    items =
      List.update_at(items, 1, &%{&1 | caption: "<b>" <> String.duplicate("b", 1025) <> "</b>"})

    assert :ok =
             Hub.respond("ai-token", req.req_id, "album", MediaAlbum.encode(items),
               caption_overflow: true
             )

    assert_receive {:sent, _, %{datatype: "album", media_items: [first, second]}}
    assert String.length(first.caption) == 1024
    assert String.starts_with?(second.caption, "<b>")
    assert_receive {:sent, _, %{datatype: "text", data: "a", reply_to_message_id: 901}}
    assert_receive {:sent, _, %{datatype: "text", data: "<b>b</b>", reply_to_message_id: 902}}
  end

  test "continuation failure closes the request and never retries the upload on another bot" do
    parent = self()

    :ok =
      Hub.configure(
        load_push_router!(),
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "bot-token"},
            %{chat_id: 123, bot_token: "backup"}
          ],
          sender: fn token, message ->
            send(parent, {:attempt, token, message.datatype})

            if message.datatype == "file",
              do: {:ok, %{message_id: 901}},
              else: {:error, %ExGram.Error{code: 401}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    req = request()

    assert {:error, :telegram_delivery_timeout} =
             Hub.respond("ai-token", req.req_id, "file", "bytes",
               caption: String.duplicate("x", 1025),
               caption_overflow: true
             )

    assert_receive {:attempt, "bot-token", "file"}
    assert_receive {:attempt, "bot-token", "text"}
    refute_receive {:attempt, _, _}
    assert {:error, :request_not_found} = Hub.respond("ai-token", req.req_id, "file", "bytes")
  end

  test "push counts chats and rejects invalid overflow options" do
    assert {:ok, 1} =
             Hub.push("ai-token", "image", "bytes", 123,
               caption: String.duplicate("x", 1025),
               caption_overflow: true
             )

    assert_receive {:sent, _, %{datatype: "image"}}
    assert_receive {:sent, _, %{datatype: "text"}}

    assert {:error, :invalid_payload} =
             Hub.push("ai-token", "text", "text", 123, caption_overflow: true)

    assert {:error, :invalid_payload} =
             Hub.push("ai-token", "file", "bytes", 123, caption_overflow: "true")
  end

  test "caption budgets are bounded across the whole album before uploading" do
    huge = String.duplicate("x", TextSplitter.max_units())

    items = [
      %{datatype: "image", data: "one", caption: huge},
      %{datatype: "image", data: "two", caption: huge}
    ]

    message =
      Message.new(222, 123, "album", MediaAlbum.encode(items), nil, caption_overflow: true)

    assert {:error, :invalid_payload} = CaptionDelivery.prepare(message)

    message =
      Message.new(222, 123, "file", "bytes", nil, caption: huge <> "x", caption_overflow: true)

    assert {:error, :invalid_payload} = CaptionDelivery.prepare(message)
    # Individual members fit the logical limit, but together exceed 32 continuations.
    caption = String.duplicate("x", 12_288)
    items = for _ <- 1..10, do: %{datatype: "image", data: "bytes", caption: caption}

    message =
      Message.new(222, 123, "album", MediaAlbum.encode(items), nil, caption_overflow: true)

    assert {:ok, _, parts} = CaptionDelivery.prepare(message)
    assert length(parts) == 30

    items =
      for _ <- 1..9,
          do: %{datatype: "image", data: "bytes", caption: String.duplicate("x", 13_313)}

    message =
      Message.new(222, 123, "album", MediaAlbum.encode(items), nil, caption_overflow: true)

    assert {:error, :invalid_payload} = CaptionDelivery.prepare(message)
  end

  test "supported caption formatting and explicit entity precedence remain usable" do
    for {caption, mode} <- [
          {"*bold* _italic_ [link](https://example.com)", "Markdown"},
          {">Expandable quote||", "MarkdownV2"},
          {"<pre><code class=\"language-elixir\">1 + 2</code></pre>", "HTML"},
          {"<blockquote expandable>Quote &amp; text</blockquote>", "HTML"},
          {"<tg-emoji emoji-id=\"123\">😀</tg-emoji>", "HTML"},
          {"escaped\\!", "MarkdownV2"}
        ] do
      message = Message.new(222, 123, "file", "bytes", nil, caption: caption, parse_mode: mode)
      assert {:ok, %{caption: ^caption}, []} = CaptionDelivery.prepare(message)
    end

    message =
      Message.new(222, 123, "file", "bytes", nil,
        caption: "<b>literal",
        parse_mode: "HTML",
        caption_entities: []
      )

    assert {:ok, _, []} = CaptionDelivery.prepare(message)
  end

  test "invalid entity ranges, types and required fields never reach Telegram" do
    for entities <- [
          [%{type: "bold", offset: 0, length: 1}],
          [%{type: "unknown", offset: 0, length: 2}],
          [%{type: "text_link", offset: 0, length: 2}],
          [%{type: "code", offset: 0, length: 2}, %{type: "bold", offset: 0, length: 2}]
        ] do
      message =
        Message.new(222, 123, "file", "bytes", nil, caption: "😀", caption_entities: entities)

      assert {:error, :invalid_payload} = CaptionDelivery.prepare(message)
    end
  end

  test "cancellation retains confirmed media IDs and prevents remaining text" do
    parent = self()

    :ok =
      Hub.configure(
        load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            if message.datatype == "file" do
              {:ok, %{message_id: 901}}
            else
              send(parent, {:blocked, self(), message.data})

              receive do
                :release -> {:ok, %{message_id: 902}}
              end
            end
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    req = request()

    task =
      start_supervised!(
        {Task,
         fn ->
           send(
             parent,
             {:result,
              Hub.respond("ai-token", req.req_id, "file", "bytes",
                caption: String.duplicate("x", 5121),
                caption_overflow: true
              )}
           )
         end}
      )

    monitor = Process.monitor(task)
    assert_receive {:blocked, worker, text}
    assert byte_size(text) == 4096

    assert {:ok, %{message_ids: [901], delivery_status: "unknown"}} =
             Hub.cancel("ai-token", req.req_id)

    assert_receive {:result, {:error, :request_cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    send(worker, :release)
    refute_receive {:blocked, _, _}
    {:ok, diagnostic} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert diagnostic.confirmed_parts == 1
    assert diagnostic.planned_parts == 3
  end

  defp request(id \\ 10) do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "bot-token",
          message_id: id,
          message_thread_id: 7
        )
      )

    {:ok, [req]} = Hub.poll("ai-token")
    req
  end
end
