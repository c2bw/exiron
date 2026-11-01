defmodule Exiron.TelegramAdapterTransportTest do
  use ExUnit.Case, async: false

  alias Exiron.TelegramAdapter

  setup do
    previous_url = Application.fetch_env(:ex_gram, :base_url)

    counter = start_supervised!({Agent, fn -> 76 end})

    server =
      start_supervised!(
        {Bandit,
         plug: {__MODULE__, test_pid: self(), counter: counter},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:ex_gram, :base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      case previous_url do
        {:ok, url} -> Application.put_env(:ex_gram, :base_url, url)
        :error -> Application.delete_env(:ex_gram, :base_url)
      end
    end)

    :ok
  end

  test "guided input prompts use selective ForceReply without a client keyboard" do
    message =
      Exiron.Hub.Message.outgoing(222, 123, "text", "Reply with your question", "local-test",
        reply_to_message_id: 9,
        parse_mode: "plain"
      )

    assert {:ok, _} =
             Exiron.Hub.Telegram.Sender.deliver("local-test", %{message | force_reply?: true})

    assert_receive {:telegram_request, "/botlocal-test/sendMessage", payload}

    markup =
      case payload["reply_markup"] do
        value when is_binary(value) -> Jason.decode!(value)
        value -> value
      end

    assert markup["force_reply"] == true
    assert markup["selective"] == true
  end

  test "polling uses a real HTTP connection with a per-request connect timeout" do
    assert {:ok, []} =
             ExGram.get_updates(
               token: "local-test",
               timeout: 0,
               adapter_opts: [connect_timeout: 1000, receive_timeout: 1000]
             )

    assert_receive {:telegram_request, "/botlocal-test/getUpdates", %{"timeout" => 0}}
  end

  test "an explicit Finch pool uses its configured connection options" do
    assert {:ok, []} =
             TelegramAdapter.request(:post, "/botlocal-test/getUpdates", %{},
               finch: Exiron.Finch,
               connect_timeout: 1000,
               receive_timeout: 1000
             )

    assert_receive {:telegram_request, "/botlocal-test/getUpdates", %{}}
  end

  test "real HTTP rate-limit responses retain retry_after without implicit retries" do
    assert {:error, %ExGram.Error{code: 429} = error} =
             TelegramAdapter.request(:post, "/botlocal-test/limited", %{}, [])

    assert error.metadata == %{parameters: %{"retry_after" => 2}}
    assert_receive {:telegram_request, "/botlocal-test/limited", %{}}
    refute_receive {:telegram_request, _, _}
  end

  test "new sender operations use real HTTP and preserve topic and formatting fields" do
    alias Exiron.Hub.Message
    alias Exiron.Hub.Telegram.Sender

    assert {:ok, %{message_id: 77}} =
             Sender.deliver(
               "local-test",
               Message.new(222, 123, "text", "hello", nil,
                 message_thread_id: 7,
                 parse_mode: "plain",
                 entities: [%{type: "bold", offset: 0, length: 5}]
               )
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "message_thread_id" => 7,
                      "entities" => [%{"type" => "bold", "offset" => 0, "length" => 5}]
                    } = payload}

    refute Map.has_key?(payload, "parse_mode")

    assert {:ok, %{message_id: 77}} =
             Sender.deliver(
               "local-test",
               Message.new(222, 123, "text", "edited", nil,
                 edit_message_id: 77,
                 parse_mode: "plain"
               )
             )

    assert_receive {:telegram_request, "/botlocal-test/editMessageText",
                    %{"message_id" => 77, "text" => "edited"}}

    assert :ok =
             Sender.send("local-test", %Message{
               datatype: "action",
               data: "typing",
               chat_id: 123,
               message_thread_id: 7
             })

    assert_receive {:telegram_request, "/botlocal-test/sendChatAction",
                    %{"action" => "typing", "message_thread_id" => 7}}
  end

  test "album uploads use multipart attachments through the production adapter" do
    alias Exiron.Hub.{MediaAlbum, Message}

    album =
      MediaAlbum.encode([
        %{datatype: "image", data: "photo-one", file_name: "one.jpg", caption: "Photos"},
        %{datatype: "video", data: "video-two", file_name: "two.mp4"}
      ])

    assert {:ok, [%{message_id: 71}, %{message_id: 72}]} =
             Exiron.Hub.Telegram.Sender.deliver(
               "local-test",
               Message.new(222, 123, "album", album, nil, message_thread_id: 7)
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMediaGroup", body}
    assert body =~ "attach://media_0_media"
    assert body =~ "one.jpg"
    assert body =~ "photo-one"
    assert body =~ "two.mp4"
    assert body =~ "video-two"
    assert body =~ "message_thread_id"
  end

  test "inline keyboards and answers serialize through the real SDK and HTTP adapter" do
    alias Exiron.Hub.{InlineKeyboard, Message}
    alias Exiron.Hub.Telegram.Sender

    message =
      Message.outgoing(222, 123, "text", "Choose", "local-test",
        inline_keyboard: [
          [%{text: "Next", callback_data: "next"}, %{text: "Help", url: "https://example.com"}]
        ]
      )
      |> InlineKeyboard.prepare("request")

    assert {:ok, %{message_id: 77}} = Sender.deliver("local-test", message)

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "reply_markup" => %{
                        "inline_keyboard" => [
                          [
                            %{"text" => "Next", "callback_data" => ref},
                            %{"url" => "https://example.com"}
                          ]
                        ]
                      }
                    }}

    assert String.starts_with?(ref, "ex:")

    assert {:ok, %{message_id: 77}} =
             Sender.deliver("local-test", %{message | edit_message_id: 77})

    assert_receive {:telegram_request, "/botlocal-test/editMessageText",
                    %{"reply_markup" => %{"inline_keyboard" => [[%{"callback_data" => ^ref}, _]]}}}

    assert {:ok, %{message_id: 77}} =
             Sender.deliver("local-test", %{
               message
               | datatype: "keyboard",
                 data: "",
                 edit_message_id: 77,
                 inline_keyboard: []
             })

    assert_receive {:telegram_request, "/botlocal-test/editMessageReplyMarkup",
                    %{"message_id" => 77, "reply_markup" => %{"inline_keyboard" => []}}}

    assert :ok = Exiron.Hub.Telegram.CallbackAnswer.answer("local-test", "query-1", :ok)

    assert_receive {:telegram_request, "/botlocal-test/answerCallbackQuery",
                    %{"callback_query_id" => "query-1"} = answer}

    refute Map.has_key?(answer, "text")

    assert :ok =
             Exiron.Hub.Telegram.CallbackAnswer.answer(
               "local-test",
               "query-2",
               {:error, :unavailable}
             )

    assert_receive {:telegram_request, "/botlocal-test/answerCallbackQuery",
                    %{"callback_query_id" => "query-2", "text" => text}}

    assert text =~ "unavailable"
  end

  test "callback acknowledgements bypass a blocked normal send for the same bot" do
    parent = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           Exiron.Hub.Telegram.SendCoordinator.run("local-test", fn ->
             send(parent, {:send_blocked, self()})

             receive do
               :release -> :ok
             end
           end)
         end}
      )

    monitor = Process.monitor(task)
    assert_receive {:send_blocked, sender}
    assert :ok = Exiron.Hub.Telegram.CallbackAnswer.answer("local-test", "prompt", :ok)

    assert_receive {:telegram_request, "/botlocal-test/answerCallbackQuery",
                    %{"callback_query_id" => "prompt"}}

    send(sender, :release)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
  end

  test "multipart replies and shrinking edits use real HTTP with bounded entities and topic" do
    alias Exiron.Hub.{Message, Telegram}
    text = String.duplicate("x", 4096) <> "tail"
    telegram = Telegram.new([%{chat_id: 123, bot_token: "local-test"}])

    message =
      Message.outgoing(222, 123, "text", text, "local-test",
        message_thread_id: 7,
        entities: [%{type: "bold", offset: 4090, length: 10}]
      )

    assert {:ok, %{text_message_ids: [77, 78]} = delivered} =
             Telegram.send_message(telegram, message)

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "text" => first,
                      "message_thread_id" => 7,
                      "entities" => [%{"offset" => 4090, "length" => 6}]
                    }}

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "text" => "tail",
                      "message_thread_id" => 7,
                      "entities" => [%{"offset" => 0, "length" => 4}]
                    }}

    assert first <> "tail" == text

    message = %{
      delivered
      | data: "short",
        entities: nil,
        parse_mode: "plain",
        edit_message_id: 77
    }

    assert {:ok, %{text_message_ids: [77]}} = Telegram.send_message(telegram, message)

    assert_receive {:telegram_request, "/botlocal-test/editMessageText",
                    %{"message_id" => 77, "text" => "short"}}

    assert_receive {:telegram_request, "/botlocal-test/deleteMessage",
                    %{"message_id" => 78, "chat_id" => 123}}
  end

  test "cancellation of real in-flight HTTP reports unknown and keeps confirmed part IDs" do
    alias Exiron.Hub
    alias Exiron.Hub.{Message, Telegram}

    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "local-test"}])
      )

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request", bot_token: "local-test")
      )

    {:ok, [request]} = Hub.poll("ai-token")
    parent = self()

    caller =
      start_supervised!(
        {Task,
         fn ->
           send(
             parent,
             {:cancelled_response,
              Hub.respond(
                "ai-token",
                request.req_id,
                "text",
                String.duplicate("x", 4096) <> "cancel-http",
                parse_mode: "plain"
              )}
           )
         end}
      )

    monitor = Process.monitor(caller)
    assert_receive {:http_blocked, peer}, 2000

    assert {:ok, %{delivery_status: "unknown", message_ids: [77]}} =
             Hub.cancel("ai-token", request.req_id)

    assert_receive {:cancelled_response, {:error, :request_cancelled}}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    send(peer, :finish_http)
    assert_receive :http_finished
    assert Hub.request_trace(request.req_id).status == :cancelled
    assert {:error, :request_cancelled} = Hub.respond("ai-token", request.req_id, "text", "late")
  end

  test "reply parameters reach Telegram on the first text part, with the original forum topic" do
    alias Exiron.Hub.{Message, Telegram}
    telegram = Telegram.new([%{chat_id: 123, bot_token: "local-test"}])

    message =
      Message.outgoing(222, 123, "text", String.duplicate("x", 4096) <> "tail", "local-test",
        reply_to_message_id: 321,
        message_thread_id: 7,
        parse_mode: "plain"
      )

    assert {:ok, %{text_message_ids: [77, 78]} = sent} = Telegram.send_message(telegram, message)

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "text" => first,
                      "message_thread_id" => 7,
                      "reply_parameters" => %{
                        "message_id" => 321,
                        "allow_sending_without_reply" => false
                      }
                    }}

    assert byte_size(first) == 4096

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{"text" => "tail", "message_thread_id" => 7} = continuation}

    refute Map.has_key?(continuation, "reply_parameters")

    assert {:ok, _} =
             Telegram.send_message(telegram, %{sent | data: "short", edit_message_id: 77})

    assert_receive {:telegram_request, "/botlocal-test/editMessageText",
                    %{"message_id" => 77} = edit}

    refute Map.has_key?(edit, "reply_parameters")

    assert_receive {:telegram_request, "/botlocal-test/deleteMessage",
                    %{"message_id" => 78} = deletion}

    refute Map.has_key?(deletion, "reply_parameters")
  end

  test "reply parameters serialize for media, stickers and album uploads" do
    alias Exiron.Hub.{MediaAlbum, Message}
    alias Exiron.Hub.Telegram.Sender
    opts = [reply_to_message_id: 321, message_thread_id: 7]

    assert {:ok, _} =
             Sender.deliver(
               "local-test",
               Message.outgoing(222, 123, "file", "file-bytes", "local-test", opts)
             )

    assert_receive {:telegram_request, "/botlocal-test/sendDocument", body}
    assert body =~ "reply_parameters"
    assert body =~ ~s("message_id":321)
    assert body =~ ~s("allow_sending_without_reply":false)
    assert body =~ "message_thread_id"

    assert {:ok, _} =
             Sender.deliver(
               "local-test",
               Message.outgoing(222, 123, "sticker", "sticker-id", "local-test", opts)
             )

    assert_receive {:telegram_request, "/botlocal-test/sendSticker",
                    %{"reply_parameters" => %{"message_id" => 321}, "message_thread_id" => 7}}

    album =
      MediaAlbum.encode([%{datatype: "image", data: "one"}, %{datatype: "video", data: "two"}])

    assert {:ok, _} =
             Sender.deliver(
               "local-test",
               Message.outgoing(222, 123, "album", album, "local-test", opts)
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMediaGroup", body}
    assert body =~ "reply_parameters"
    assert body =~ ~s("message_id":321)
  end

  test "an unavailable original is not silently retried without a reply reference" do
    alias Exiron.Hub
    alias Exiron.Hub.{Message, Telegram}

    :ok =
      Hub.configure(
        Exiron.HubCase.load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "local-test"}])
      )

    {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "local-test",
          message_id: 404,
          message_thread_id: 7
        )
      )

    {:ok, [req]} = Hub.poll("ai-token")

    assert {:error, %ExGram.Error{code: 400}} =
             Hub.respond("ai-token", req.req_id, "text", "reply",
               reply_to_original: true,
               parse_mode: "plain"
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{"reply_parameters" => %{"message_id" => 404}}}

    refute_receive {:telegram_request, "/botlocal-test/sendMessage", _}
    {:ok, diagnostic} = Hub.delivery_diagnostics("ai-token", req.req_id)
    assert diagnostic.rejected_parts == 1
    assert diagnostic.last_error.code == 400

    assert :ok =
             Hub.respond("ai-token", req.req_id, "text", "explicitly unrelated",
               reply_to_original: false,
               parse_mode: "plain"
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{"text" => "explicitly unrelated"} = payload}

    refute Map.has_key?(payload, "reply_parameters")
  end

  test "caption overflow uploads once then sends formatted text linked to its media" do
    alias Exiron.Hub.{Message, Telegram}
    telegram = Telegram.new([%{chat_id: 123, bot_token: "local-test"}])

    message =
      Message.outgoing(222, 123, "file", "file-bytes", "local-test",
        caption: String.duplicate("x", 1025),
        caption_overflow: true,
        caption_entities: [%{type: "bold", offset: 1000, length: 25}],
        message_thread_id: 7
      )

    assert {:ok, %{message_id: 77}} = Telegram.send_message(telegram, message)
    assert_receive {:telegram_request, "/botlocal-test/sendDocument", body}
    assert body =~ "file-bytes"
    assert body =~ ~s("length":24)

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "text" => "x",
                      "entities" => [%{"type" => "bold", "offset" => 0, "length" => 1}],
                      "message_thread_id" => 7,
                      "reply_parameters" => %{"message_id" => 77}
                    }}

    refute_receive {:telegram_request, _, _}
  end

  test "album caption overflow retains member HTML formatting on the real wire" do
    alias Exiron.Hub.{MediaAlbum, Message, Telegram}
    telegram = Telegram.new([%{chat_id: 123, bot_token: "local-test"}])

    data =
      MediaAlbum.encode([
        %{
          datatype: "image",
          data: "one",
          caption: "<b>" <> String.duplicate("x", 1025) <> "</b>",
          parse_mode: "HTML"
        },
        %{datatype: "video", data: "two"}
      ])

    assert {:ok, %{message_id: 71}} =
             Telegram.send_message(
               telegram,
               Message.outgoing(222, 123, "album", data, "local-test",
                 caption_overflow: true,
                 message_thread_id: 7
               )
             )

    assert_receive {:telegram_request, "/botlocal-test/sendMediaGroup", body}
    assert body =~ ~s("parse_mode":"HTML")

    assert_receive {:telegram_request, "/botlocal-test/sendMessage",
                    %{
                      "text" => "<b>x</b>",
                      "parse_mode" => "HTML",
                      "reply_parameters" => %{"message_id" => 71},
                      "message_thread_id" => 7
                    }}
  end

  # Run the production Req/Finch transport against an isolated loopback peer.
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    payload =
      if String.starts_with?(
           List.first(Plug.Conn.get_req_header(conn, "content-type")) || "",
           "application/json"
         ), do: Jason.decode!(body), else: body

    send(opts[:test_pid], {:telegram_request, conn.request_path, payload})

    if is_map(payload) and payload["text"] == "cancel-http" do
      send(opts[:test_pid], {:http_blocked, self()})

      receive do
        :finish_http -> :ok
      end

      send(opts[:test_pid], :http_finished)
    end

    {status, response} =
      cond do
        String.ends_with?(conn.request_path, "/limited") ->
          {429,
           %{
             ok: false,
             error_code: 429,
             description: "Too Many Requests",
             parameters: %{retry_after: 2}
           }}

        is_map(payload) and is_map(payload["reply_parameters"]) and
            payload["reply_parameters"]["message_id"] == 404 ->
          {400,
           %{
             ok: false,
             error_code: 400,
             description: "Bad Request: message to be replied not found"
           }}

        true ->
          result =
            cond do
              String.ends_with?(conn.request_path, "/sendMediaGroup") ->
                [%{message_id: 71}, %{message_id: 72}]

              String.ends_with?(conn.request_path, "/sendChatAction") or
                  String.ends_with?(conn.request_path, "/answerCallbackQuery") ->
                true

              String.ends_with?(conn.request_path, "/sendDocument") or
                  String.ends_with?(conn.request_path, "/sendSticker") ->
                %{message_id: 77}

              String.ends_with?(conn.request_path, "/sendMessage") ->
                %{message_id: Agent.get_and_update(opts[:counter], &{&1 + 1, &1 + 1})}

              String.ends_with?(conn.request_path, "/editMessageText") or
                  String.ends_with?(conn.request_path, "/editMessageReplyMarkup") ->
                %{message_id: payload["message_id"]}

              String.ends_with?(conn.request_path, "/deleteMessage") ->
                true

              true ->
                []
            end

          {200, %{ok: true, result: result}}
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(response))
  end
end
