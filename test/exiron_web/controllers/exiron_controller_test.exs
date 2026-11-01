defmodule ExironWeb.ExironControllerTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{AuthenticatedHook, Message, Telegram}
  import Exiron.Support.RouterHelper

  setup do
    router = load_router!()
    :ok = Hub.configure(router, Telegram.new([]))
    :ok
  end

  test "authenticates clients with a hook token", %{conn: conn} do
    conn = post(conn, ~p"/api/auth", %{hook_token: "ai-token"})

    assert %{
             "auth_response" => "OK",
             "hook" => "assistant",
             "msgtype" => "auth",
             "protocol_version" => protocol_version,
             "capabilities" => capabilities
           } = json_response(conn, 200)

    assert protocol_version == Exiron.Protocol.protocol_version()
    assert capabilities == Exiron.Protocol.capabilities()
  end

  test "rate limits authentication before parsing its request body", %{conn: conn} do
    now = System.system_time(:second)

    :ets.insert(
      :rate_limit_entries,
      {{:api_authentication, "127.0.0.1", now}, 10}
    )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth", "{")

    assert %{"error" => "too many requests"} = json_response(conn, 429)
  end

  test "rejects invalid bearer authentication before parsing API bodies", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/push", "{")

    assert %{"code" => "invalid_token", "error" => "invalid token"} = json_response(conn, 401)
  end

  test "rejects invalid UTF-8 text payloads", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{datatype: "text", data: Base.encode64(<<0xFF>>)})

    assert %{"error" => "invalid payload"} = json_response(conn, 400)
  end

  test "caps unauthenticated API authentication bodies", %{conn: conn} do
    body = Jason.encode!(%{hook_token: String.duplicate("x", 16 * 1024)})

    assert_error_sent 413, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/auth", body)
    end
  end

  test "requires bearer authentication for hub status", %{conn: conn} do
    conn = get(conn, ~p"/api/status")

    assert %{"error" => "missing bearer token"} = json_response(conn, 401)
  end

  test "socket endpoint requires bearer authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/socket?client_id=client")

    assert %{"error" => "missing bearer token"} = json_response(conn, 401)
  end

  test "socket endpoint rejects invalid bearer tokens", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> get(~p"/api/socket?client_id=client")

    assert %{"error" => "invalid token"} = json_response(conn, 401)
  end

  test "rejects dashboard sessions without bearer tokens for hub status", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> recycle()
      |> get(~p"/api/status")

    assert %{"error" => "missing bearer token"} = json_response(conn, 401)
  end

  test "rejects invalid bearer tokens for hub status", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> get(~p"/api/status")

    assert %{"error" => "invalid token"} = json_response(conn, 401)
  end

  test "returns hub status for authenticated bearer clients", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    assert %{"enabled" => true, "requested" => 0, "hooks" => hooks} = json_response(conn, 200)
    assert is_list(hooks)
    assert json_response(conn, 200)["telegram_polling"] == false
    assert is_nil(json_response(conn, 200)["telegram_last_polled_at"])
    assert %AuthenticatedHook{name: "assistant"} = conn.assigns.api_authentication
  end

  test "scopes status data to the authenticated hook", %{conn: conn} do
    router =
      load_router!("controller-scoped-status", """
      aliases:
        telegram:
          assistant_chat: 123
          status_chat: 456
      routes:
        assistant_chat:
          middleware:
            - assistant
        status_chat:
          middleware:
            - status
      middlewares:
        assistant:
          routes:
            assistant:
              messages:
                - "/ai"
        status:
          routes:
            status:
              messages:
                - "/status"
      hooks:
        assistant: "ai-token"
        status: "status-token"
      """)

    :ok = Hub.configure(router, Telegram.new([]))
    assert {:ok, []} = Hub.poll("ai-token", client_id: "assistant-client")
    assert {:ok, []} = Hub.poll("status-token", client_id: "status-client")

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello"))
    :ok = Hub.incoming_service_message(Message.new(222, 456, "text", "/status secret"))

    :ok =
      Hub.telegram_membership_changed(%{
        action: "added",
        chat_id: 456,
        chat_title: "Private status chat",
        bot_token: "private-bot-token",
        bot_name: "private-bot",
        bot_user_id: 456_789,
        old_status: "left",
        new_status: "member"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    status = json_response(conn, 200)

    assert [%{"hook" => "assistant", "client_id" => "assistant-client"}] =
             status["client_events"]

    assert [%{"name" => "assistant"}] = status["hooks"]
    assert [%{"to" => "assistant", "chat_id" => 123}] = status["routes"]
    assert [%{"id" => 123}] = status["chats"]
    assert status["requested"] == 1
    assert status["events"] != []
    assert Enum.all?(status["events"], &(&1["hook"] == "assistant"))
    assert status["membership_events"] == []
    assert status["bot_memberships"] == []

    encoded = Jason.encode!(status)
    refute encoded =~ "status-token"
    refute encoded =~ "status-client"
    refute encoded =~ "Private status chat"
    refute encoded =~ "/status"
    refute encoded =~ ~s("chat_id":456)

    global = Hub.status()
    assert global.requested == 2
    assert Enum.sort(Enum.map(global.hooks, & &1.name)) == ["assistant", "status"]
  end

  test "never exposes Telegram bot tokens in hub status", %{conn: conn} do
    bot_token = "123456:super-secret-bot-token"
    failure = {:transport_error, "request failed for #{bot_token}"}

    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: bot_token, bot_name: "assistant-bot"}],
        sender: fn _, _ -> {:error, failure} end
      )

    :ok = Hub.configure(load_router!(), telegram)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "status-client")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", bot_token, bot_name: "assistant-bot")
      )

    assert {:ok, [%{req_id: request_id}]} =
             Hub.poll("ai-token", client_id: "status-client")

    assert {:error, ^failure} = Hub.respond("ai-token", request_id, "text", "hello back")

    :ok =
      Hub.telegram_membership_changed(%{
        action: "removed",
        chat_id: 123,
        chat_title: "Family",
        bot_token: bot_token,
        bot_name: "assistant-bot",
        bot_user_id: 654_321,
        old_status: "member",
        new_status: "left"
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    status = json_response(conn, 200)

    refute nested_key?(status, "bot_token")
    refute Jason.encode!(status) =~ bot_token
    assert [%{"reason" => reason}] = status["send_failures"]
    assert reason =~ "[REDACTED]"
  end

  test "fetching hub status does not create a client lease", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    assert %{"enabled" => true, "hooks" => hooks} = json_response(conn, 200)
    assert is_list(hooks)
    assert [%{connected: false}] = Hub.status().hooks
  end

  test "returns Telegram message ids in hub status events", %{conn: conn} do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "event-client")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", "bot-token",
          bot_name: "assistant-bot",
          message_id: 1234,
          reply_to_message_id: 1201
        )
      )

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    assert %{"events" => [event | _events]} = json_response(conn, 200)
    assert event["bot_name"] == "assistant-bot"
    assert event["message_id"] == 1234
    assert event["reply_to_message_id"] == 1201
  end

  test "queues matching Telegram messages for HTTP polling clients", %{conn: conn} do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "test-client")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", "bot-token", bot_name: "assistant-bot")
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=test-client")

    assert %{"requests" => [request]} = json_response(conn, 200)
    assert request["msgtype"] == "request"
    assert request["service_id"] == 222
    assert request["chat_id"] == 123
    assert request["instance"] == "assistant-bot"
    assert request["datatype"] == "text"
    assert Base.decode64!(request["data"]) == "/ai hello"
    assert is_nil(request["message_id"])
    assert is_nil(request["reply_to_message_id"])
  end

  test "includes Telegram message metadata in queued HTTP polling requests", %{conn: conn} do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "test-client")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai hello", "bot-token",
          bot_name: "assistant-bot",
          message_id: 1234,
          reply_to_message_id: 1201,
          from: %{
            id: 42,
            is_bot: false,
            first_name: "Ada",
            last_name: "Lovelace",
            username: "ada",
            language_code: "en"
          }
        )
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=test-client")

    assert %{"requests" => [request]} = json_response(conn, 200)
    assert request["message_id"] == 1234
    assert request["reply_to_message_id"] == 1201
    assert request["instance"] == "assistant-bot"
    assert request["from"]["id"] == 42
    assert request["from"]["first_name"] == "Ada"
    assert request["from"]["username"] == "ada"
  end

  test "includes sticker emoji metadata in queued HTTP polling requests and status", %{conn: conn} do
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

    assert {:ok, []} = Hub.poll("ai-token", client_id: "test-client", listen: true)

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "file", "sticker bytes", "bot-token",
          sticker_id: "sticker-id",
          sticker_emoji: sticker_emoji
        )
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=test-client&listen=true")

    assert %{"requests" => [request]} = json_response(conn, 200)
    assert request["msgtype"] == "listen"
    assert request["datatype"] == "file"
    assert request["sticker_id"] == "sticker-id"
    assert request["sticker_emoji"] == sticker_emoji
    assert request["emoji_list"] == emoji_list

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/status")

    assert %{"events" => [event | _events]} = json_response(conn, 200)
    assert event["sticker_id"] == "sticker-id"
    assert event["sticker_emoji"] == sticker_emoji
    assert event["emoji_list"] == emoji_list
  end

  test "polling with listen renews the listen subscription", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=listener&listen=true")

    assert %{"requests" => []} = json_response(conn, 200)
    assert [%{connected: true, listening: true}] = Hub.status().hooks
  end

  test "explicit polling exposes and accepts delivery acknowledgements", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=reliable&delivery_mode=explicit")

    assert %{"delivery_id" => nil, "requests" => []} = json_response(conn, 200)

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=reliable&delivery_mode=explicit")

    assert %{"delivery_id" => delivery_id, "requests" => [request]} = json_response(conn, 200)

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(
        "/api/requests?" <>
          URI.encode_query(%{
            "client_id" => "reliable",
            "delivery_mode" => "explicit",
            "delivery_ack" => delivery_id
          })
      )

    assert %{"delivery_id" => nil, "requests" => []} = json_response(conn, 200)
    assert request["msgtype"] == "request"
  end

  test "polling with listen all receives routed messages as listen and request", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=listener&listen=all")

    assert %{"requests" => []} = json_response(conn, 200)

    :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=listener&listen=all")

    assert %{"requests" => [request, listen]} = json_response(conn, 200)
    assert listen["msgtype"] == "listen"
    assert request["msgtype"] == "request"
  end

  test "rejects a second polling client for the same hook token", %{conn: conn} do
    assert {:ok, []} = Hub.poll("ai-token", client_id: "active-client")

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests?client_id=other-client")

    assert %{"error" => "hook already connected", "retry_after_ms" => retry_after_ms} =
             json_response(conn, 409)

    assert retry_after_ms in 1..3000
  end

  test "rejects unknown bearer tokens", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer nope")
      |> get(~p"/api/requests")

    assert %{"error" => "invalid token"} = json_response(conn, 401)
  end

  test "requires bearer tokens for polling clients", %{conn: conn} do
    conn = get(conn, ~p"/api/requests?client_id=test-client")

    assert %{"error" => "missing bearer token"} = json_response(conn, 401)
  end

  test "requires a client instance id when polling", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> get(~p"/api/requests")

    assert %{"error" => "invalid client id"} = json_response(conn, 400)
  end

  test "serializes tuple-shaped downstream errors", %{conn: conn} do
    router = load_router!()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, _ -> {:error, {:bad_status, 500}} end
      )

    :ok = Hub.configure(router, telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{datatype: "text", data: Base.encode64("hello")})

    assert %{"code" => "internal_error", "error" => "internal error"} =
             json_response(conn, 500)
  end

  test "serializes Telegram forbidden errors from push", %{conn: conn} do
    kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, _ -> {:error, kicked} end
      )

    :ok = Hub.configure(load_router!(), telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{datatype: "text", data: Base.encode64("hello")})

    assert %{"error" => "telegram bot forbidden"} = json_response(conn, 503)
  end

  test "serializes Telegram unauthorized errors from push", %{conn: conn} do
    unauthorized = %ExGram.Error{code: 401, message: "Unauthorized"}

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, _ -> {:error, unauthorized} end
      )

    :ok = Hub.configure(load_router!(), telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{datatype: "text", data: Base.encode64("hello")})

    assert %{"error" => "telegram bot unauthorized"} = json_response(conn, 503)
  end

  test "pushes only to the requested routed chat", %{conn: conn} do
    parent = self()

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "home-token"},
          %{chat_id: 456, bot_token: "work-token"}
        ],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    :ok = Hub.configure(load_multi_chat_router!(), telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{
        datatype: "text",
        data: Base.encode64("hello"),
        chat_id: 456
      })

    assert %{"ok" => true, "sent" => 1} = json_response(conn, 200)
    assert_receive {:telegram_sent, "work-token", %Message{chat_id: 456, data: "hello"}}
    refute_receive {:telegram_sent, "home-token", _message}
  end

  test "pushes with a requested Telegram bot", %{conn: conn} do
    parent = self()

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"},
          %{chat_id: 123, bot_token: "second-token", bot_name: "second-bot"}
        ],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    :ok = Hub.configure(load_router!(), telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{
        datatype: "text",
        data: Base.encode64("hello"),
        bot: "second-bot"
      })

    assert %{"ok" => true, "sent" => 1} = json_response(conn, 200)
    assert_receive {:telegram_sent, "second-token", %Message{data: "hello"}}
    refute_receive {:telegram_sent, "first-token", _message}
  end

  test "rejects pushes with unknown Telegram bot names", %{conn: conn} do
    :ok =
      Hub.configure(
        load_router!(),
        Telegram.new([
          %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"}
        ])
      )

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{
        datatype: "text",
        data: Base.encode64("hello"),
        bot: "second-bot"
      })

    assert %{"error" => "telegram bot not configured"} = json_response(conn, 503)
  end

  test "pushes Telegram stickers", %{conn: conn} do
    parent = self()
    sticker_emoji = "\u{1F525}"

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    :ok = Hub.configure(load_router!(), telegram)

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{
        datatype: "sticker",
        data: Base.encode64("sticker-file-id"),
        sticker_emoji: sticker_emoji
      })

    assert %{"ok" => true, "sent" => 1} = json_response(conn, 200)

    assert_receive {:telegram_sent, "bot-token",
                    %Message{
                      datatype: "sticker",
                      data: "sticker-file-id",
                      sticker_emoji: ^sticker_emoji
                    }}

    assert [
             %{
               datatype: "sticker",
               sticker_id: "sticker-file-id",
               sticker_emoji: ^sticker_emoji
             }
             | _events
           ] =
             Hub.status().events
  end

  test "rejects a targeted chat that is not push-enabled for the client", %{conn: conn} do
    :ok = Hub.configure(load_multi_chat_router!(), Telegram.new([]))

    conn =
      conn
      |> put_req_header("authorization", "Bearer ai-token")
      |> post(~p"/api/push", %{
        datatype: "text",
        data: Base.encode64("hello"),
        chat_id: 999
      })

    assert %{"error" => "chat not pushable"} = json_response(conn, 400)
  end

  defp load_router! do
    load_router!("controller", """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  defp load_multi_chat_router! do
    load_router!("controller-multi-chat", """
    aliases:
      telegram:
        home: 123
        work: 456
    routes:
      home:
        middleware:
          - family
        push: true
      work:
        middleware:
          - family
        push: true
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """)
  end

  defp nested_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &nested_key?(&1, key))
  end

  defp nested_key?(list, key) when is_list(list), do: Enum.any?(list, &nested_key?(&1, key))
  defp nested_key?(_value, _key), do: false
end
