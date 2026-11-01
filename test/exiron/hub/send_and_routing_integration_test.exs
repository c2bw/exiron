defmodule Exiron.Hub.SendAndRoutingIntegrationTest do
  use Exiron.HubCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  test "OTP status does not expose configured hook or Telegram tokens" do
    status = Hub |> :sys.get_status() |> inspect()

    refute status =~ "ai-token"
    refute status =~ "bot-token"
  end

  describe "request routing and responses" do
    test "incoming messages wait until the hub accepts them" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = :sys.suspend(Hub)
      parent = self()

      task =
        Task.async(fn ->
          send(parent, :incoming_call_started)
          Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
        end)

      try do
        assert_receive :incoming_call_started
        assert Task.yield(task, 100) == nil
      after
        :ok = :sys.resume(Hub)
      end

      assert Task.await(task) == :ok
      assert map_size(:sys.get_state(Hub).delivery.pending) == 1
    end

    test "responding to a pending request removes it and cancels its expiry timer" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      state = :sys.get_state(Hub)
      [{request_id, pending}] = Map.to_list(state.delivery.pending)
      assert is_integer(Process.read_timer(pending.timer))

      assert :ok = Hub.respond("ai-token", request_id, "text", "hello back")

      assert_receive {:telegram_sent, "bot-token", %Message{data: "hello back"}}
      refute Map.has_key?(:sys.get_state(Hub).delivery.pending, request_id)
      assert Process.read_timer(pending.timer) == false
    end

    test "passthrough routes strip the matched command prefix before delivering to the hook" do
      router =
        load_router!("hub-passthrough-route", """
        aliases:
          telegram:
            home: 123
        routes:
          home:
            middleware:
              - family
        middlewares:
          family:
            routes:
              assistant:
                messages:
                  - "/example"
                passthrough: true
        hooks:
          assistant: "ai-token"
        """)

      :ok =
        Hub.configure(
          router,
          Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: telegram_sender(self()))
        )

      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(Message.new(222, 123, "text", "/example new", "bot-token"))

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert Base.decode64!(request.data) == "/new"
    end

    test "hub remains responsive while a Telegram response send is in flight" do
      parent = self()
      send_ref = make_ref()

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn token, message ->
            send(parent, {:telegram_send_started, send_ref, self(), token, message})

            receive do
              {:finish_telegram_send, ^send_ref} -> :ok
            end
          end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      task = Task.async(fn -> Hub.respond("ai-token", request_id, "text", "hello back") end)

      assert_receive {:telegram_send_started, ^send_ref, sender_pid, "bot-token",
                      %Message{data: "hello back"}}

      assert %{requested: 1} = Hub.status()
      assert {:error, :request_in_flight} = Hub.respond("ai-token", request_id, "text", "retry")

      send(sender_pid, {:finish_telegram_send, send_ref})
      assert Task.await(task) == :ok
      assert %{requested: 0} = Hub.status()
    end

    test "respond returns a delivery timeout when Telegram does not finish in time" do
      parent = self()
      send_ref = make_ref()

      hub_config = Application.get_env(:exiron, :hub, [])
      Application.put_env(:exiron, :hub, Keyword.put(hub_config, :send_timeout, 20))

      on_exit(fn ->
        Application.put_env(:exiron, :hub, hub_config)
      end)

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn token, message ->
            send(parent, {:telegram_send_started, send_ref, self(), token, message})

            receive do
              {:finish_telegram_send, ^send_ref} -> :ok
            end
          end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      caller = Task.async(fn -> Hub.respond("ai-token", request_id, "text", "hello back") end)

      assert_receive {:telegram_send_started, ^send_ref, sender_pid, "bot-token",
                      %Message{data: "hello back"}}

      monitor_ref = Process.monitor(sender_pid)
      assert {:error, :telegram_delivery_timeout} = Task.await(caller)
      assert_receive {:DOWN, ^monitor_ref, :process, ^sender_pid, _reason}

      state = :sys.get_state(Hub)
      refute Map.has_key?(state.delivery.pending, request_id)
      assert state.delivery.sends == %{}

      assert [%{reason: ":telegram_delivery_timeout"} | _failures] =
               Hub.status().send_failures
    end

    test "respond fails immediately and remains retryable when its send task crashes" do
      parent = self()

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _token, _message ->
            send(parent, {:telegram_send_started, self()})

            receive do
              :never -> :ok
            end
          end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      caller = Task.async(fn -> Hub.respond("ai-token", request_id, "text", "hello back") end)

      assert_receive {:telegram_send_started, sender_pid}
      Process.exit(sender_pid, :kill)

      assert {:error, {:exit, :killed}} = Task.await(caller)

      state = :sys.get_state(Hub)
      assert state.delivery.sends == %{}
      refute Map.get(state.delivery.pending[request_id], :responding?)
    end

    test "expiry stops active response sends without leaving nil pending entries" do
      parent = self()
      send_ref = make_ref()

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn token, message ->
            send(parent, {:telegram_send_started, send_ref, self(), token, message})

            receive do
              {:finish_telegram_send, ^send_ref} -> {:error, :telegram_unavailable}
            end
          end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      caller =
        start_supervised!(
          {Task,
           fn ->
             send(
               parent,
               {:expired_response, Hub.respond("ai-token", request_id, "text", "hello back")}
             )
           end}
        )

      caller_monitor = Process.monitor(caller)

      assert_receive {:telegram_send_started, ^send_ref, sender_pid, "bot-token",
                      %Message{data: "hello back"}}

      sender_monitor = Process.monitor(sender_pid)
      send(Hub, {:expire_request, request_id})
      assert :sys.get_state(Hub).delivery.pending == %{}

      assert_receive {:expired_response, {:error, :request_not_found}}
      assert_receive {:DOWN, ^sender_monitor, :process, ^sender_pid, :killed}
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
      assert :sys.get_state(Hub).delivery.pending == %{}
    end

    test "respond rejects new sends when the in-flight send cap is reached" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      :sys.replace_state(
        Hub,
        &%{
          &1
          | settings: %{&1.settings | max_in_flight_sends: 1},
            delivery: %{&1.delivery | sends: %{make_ref() => :occupied}}
        }
      )

      assert {:error, :send_queue_full} =
               Hub.respond("ai-token", request_id, "text", "hello back")

      pending = :sys.get_state(Hub).delivery.pending[request_id]
      refute Map.get(pending, :responding?)
    end

    test "respond returns an error and stays retryable when send task start fails" do
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, _pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      with_send_supervisor_stopped(fn ->
        assert {:error, :send_unavailable} =
                 Hub.respond("ai-token", request_id, "text", "hello back")

        state = :sys.get_state(Hub)
        refute Map.get(state.delivery.pending[request_id], :responding?)
        assert state.delivery.sends == %{}
        assert Exiron.Hub.SendBudget.usage(state) == 0
      end)
    end

    test "rejects newest routed request when the pending request cap is reached" do
      assert {:ok, []} = Hub.poll("ai-token")

      :sys.replace_state(Hub, &%{&1 | settings: %{&1.settings | max_pending: 1}})

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai first", "bot-token"))
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))

      assert map_size(:sys.get_state(Hub).delivery.pending) == 1
      assert {:ok, [request]} = Hub.poll("ai-token")
      assert Base.decode64!(request.data) == "/ai first"

      assert_receive {:telegram_sent, "bot-token",
                      %Message{
                        datatype: "text",
                        data: "Hook assistant is overloaded. Please try again later."
                      }}

      assert [%{hook: "assistant", reason: :max_pending} | _events] = Hub.status().overload_events
    end

    test "rejects newest routed request when the hook queue cap is reached" do
      assert {:ok, []} = Hub.poll("ai-token")

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_per_hook: 1}}
      )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai first", "bot-token"))
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai second", "bot-token"))

      assert map_size(:sys.get_state(Hub).delivery.pending) == 1
      assert {:ok, [request]} = Hub.poll("ai-token")
      assert Base.decode64!(request.data) == "/ai first"

      assert_receive {:telegram_sent, "bot-token",
                      %Message{data: "Hook assistant is overloaded. Please try again later."}}

      assert [%{hook: "assistant", reason: :max_queue_per_hook} | _events] =
               Hub.status().overload_events
    end

    test "rejects routed request when the hook queue byte cap would be exceeded" do
      assert {:ok, []} = Hub.poll("ai-token")

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_queue_bytes_per_hook: 7}}
      )

      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))

      assert :sys.get_state(Hub).delivery.pending == %{}
      assert {:ok, []} = Hub.poll("ai-token")

      assert_receive {:telegram_sent, "bot-token",
                      %Message{data: "Hook assistant is overloaded. Please try again later."}}

      assert [%{hook: "assistant", reason: :max_queue_bytes_per_hook} | _events] =
               Hub.status().overload_events
    end

    test "forbidden Telegram reply reports failure and completes the pending request" do
      kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:error, kicked} end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")
      :ok = Hub.incoming_service_message(Message.new(222, 123, "text", "/ai hello", "bot-token"))
      [{request_id, pending}] = Map.to_list(:sys.get_state(Hub).delivery.pending)

      assert {:error, :telegram_bot_forbidden} =
               Hub.respond("ai-token", request_id, "text", "hello back")

      refute Map.has_key?(:sys.get_state(Hub).delivery.pending, request_id)
      assert Process.read_timer(pending.timer) == false
      assert [%{kind: "response_failed"} | _events] = Hub.status().events

      assert [
               %{
                 operation: "reply",
                 hook: "assistant",
                 chat_id: 123,
                 datatype: "text",
                 preview: "hello back",
                 reason: ":telegram_bot_forbidden"
               }
             ] = Hub.status().send_failures
    end

    test "responding to a pending request uses the Telegram bot that created it" do
      :ok = Hub.configure(load_router!(), multi_bot_telegram(self()))
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "second-token", bot_name: "second-bot")
        )

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.instance == "second-bot"
      assert :ok = Hub.respond("ai-token", request.req_id, "text", "hello back")

      assert_receive {:telegram_sent, "second-token", %Message{data: "hello back"}}
      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "responding falls back to a healthy bot in the same chat when the original bot was removed" do
      parent = self()
      kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

      telegram =
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "removed-token", bot_name: "removed-bot"},
            %{chat_id: 123, bot_token: "healthy-token", bot_name: "healthy-bot"}
          ],
          sender: fn
            "removed-token", _message ->
              {:error, kicked}

            token, message ->
              send(parent, {:telegram_sent, token, message})
              :ok
          end
        )

      :ok = Hub.configure(load_router!(), telegram)
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "removed-token", bot_name: "removed-bot")
        )

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.instance == "removed-bot"
      assert :ok = Hub.respond("ai-token", request.req_id, "text", "hello back")

      assert_receive {:telegram_sent, "healthy-token",
                      %Message{data: "hello back", bot_name: "healthy-bot"}}

      refute Map.has_key?(:sys.get_state(Hub).delivery.pending, request.req_id)
      assert [%{kind: "response", bot_name: "healthy-bot"} | _events] = Hub.status().events
    end

    test "responding with a sticker uses the Telegram bot that created the request" do
      sticker_emoji = "\u{1F525}"

      :ok = Hub.configure(load_router!(), multi_bot_telegram(self()))
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "second-token", bot_name: "second-bot")
        )

      assert {:ok, [request]} = Hub.poll("ai-token")

      assert :ok =
               Hub.respond("ai-token", request.req_id, "sticker", "sticker-file-id",
                 sticker_emoji: sticker_emoji
               )

      assert_receive {:telegram_sent, "second-token",
                      %Message{
                        datatype: "sticker",
                        data: "sticker-file-id",
                        sticker_emoji: ^sticker_emoji
                      }}

      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "responding uses the source bot name when the pending request has no token" do
      :ok = Hub.configure(load_router!(), multi_bot_telegram(self()))
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", nil, bot_name: "second-bot")
        )

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.instance == "second-bot"
      assert :ok = Hub.respond("ai-token", request.req_id, "text", "hello back")

      assert_receive {:telegram_sent, "second-token",
                      %Message{data: "hello back", bot_name: "second-bot"}}

      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "duplicate Telegram updates from multiple bots only route once" do
      :ok = Hub.configure(load_router!(), multi_bot_telegram(self()))
      assert {:ok, []} = Hub.poll("ai-token")

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "first-token",
            bot_name: "first-bot",
            message_id: 808
          )
        )

      :ok =
        Hub.incoming_service_message(
          Message.new(222, 123, "text", "/ai hello", "second-token",
            bot_name: "second-bot",
            message_id: 808
          )
        )

      assert {:ok, [request]} = Hub.poll("ai-token")
      assert request.msgtype == "request"
      assert request.instance == "first-bot"
      assert Hub.status().requested == 1
    end
  end

  describe "push delivery" do
    test "push uses the configured default Telegram bot for a chat with multiple bots" do
      :ok = Hub.configure(load_push_router!(), multi_bot_telegram(self()))
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello")

      assert_receive {:telegram_sent, "first-token", %Message{datatype: "text", data: "hello"}}
      refute_receive {:telegram_sent, "second-token", _message}
    end

    test "status reports the configured default Telegram bot for a chat with multiple bots" do
      :ok = Hub.configure(load_push_router!(), multi_bot_telegram(self()))

      assert [%{default_bot: "first-bot", current_bot: "first-bot"}] = Hub.status().chats
    end

    test "push can target a configured Telegram bot by name" do
      :ok = Hub.configure(load_push_router!(), multi_bot_telegram(self()))
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello", nil, bot: "second-bot")

      assert_receive {:telegram_sent, "second-token",
                      %Message{datatype: "text", data: "hello", bot_name: "second-bot"}}

      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "explicit named push falls back to a healthy bot in the same chat when the named bot was removed" do
      parent = self()
      kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

      telegram =
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "removed-token", bot_name: "removed-bot"},
            %{chat_id: 123, bot_token: "healthy-token", bot_name: "healthy-bot"}
          ],
          sender: fn
            "removed-token", _message ->
              {:error, kicked}

            token, message ->
              send(parent, {:telegram_sent, token, message})
              :ok
          end
        )

      :ok = Hub.configure(load_push_router!(), telegram)
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello", nil, bot: "removed-bot")

      assert_receive {:telegram_sent, "healthy-token",
                      %Message{datatype: "text", data: "hello", bot_name: "healthy-bot"}}

      assert [%{kind: "push", bot_name: "healthy-bot"} | _events] = Hub.status().events

      refute_receive {:telegram_sent, "removed-token", _message}
    end

    test "push uses the route default Telegram bot when configured" do
      :ok = Hub.configure(load_default_bot_push_router!(), multi_bot_telegram(self()))
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello")

      assert_receive {:telegram_sent, "second-token",
                      %Message{datatype: "text", data: "hello", bot_name: "second-bot"}}

      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "explicit push bot overrides the route default Telegram bot" do
      :ok = Hub.configure(load_default_bot_push_router!(), multi_bot_telegram(self()))
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello", nil, bot: "first-bot")

      assert_receive {:telegram_sent, "first-token",
                      %Message{datatype: "text", data: "hello", bot_name: "first-bot"}}

      refute_receive {:telegram_sent, "second-token", _message}
    end

    test "push rejects unknown Telegram bot names" do
      :ok = Hub.configure(load_push_router!(), multi_bot_telegram(self()))

      assert {:error, :telegram_bot_not_configured} =
               Hub.push("ai-token", "text", "hello", nil, bot: "missing-bot")

      refute_receive {:telegram_sent, _token, _message}
    end

    test "push falls back to another configured bot when the default bot was kicked" do
      parent = self()
      kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

      telegram =
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"},
            %{chat_id: 123, bot_token: "second-token", bot_name: "second-bot"}
          ],
          sender: fn
            "first-token", _message ->
              {:error, kicked}

            token, message ->
              send(parent, {:telegram_sent, token, message})
              :ok
          end
        )

      :ok = Hub.configure(load_push_router!(), telegram)
      assert {:ok, 1} = Hub.push("ai-token", "text", "hello")

      assert_receive {:telegram_sent, "second-token", %Message{datatype: "text", data: "hello"}}
      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "sticker push uses the configured default Telegram bot for a chat with multiple bots" do
      sticker_emoji = "\u{1F525}"

      :ok = Hub.configure(load_push_router!(), multi_bot_telegram(self()))

      assert {:ok, 1} =
               Hub.push("ai-token", "sticker", "sticker-file-id", nil,
                 sticker_emoji: sticker_emoji
               )

      assert_receive {:telegram_sent, "first-token",
                      %Message{
                        datatype: "sticker",
                        data: "sticker-file-id",
                        sticker_emoji: ^sticker_emoji
                      }}

      refute_receive {:telegram_sent, "second-token", _message}
    end

    test "sticker push falls back to another configured bot when the default bot was kicked" do
      parent = self()
      sticker_emoji = "\u{1F525}"
      kicked = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

      telegram =
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "first-token", bot_name: "first-bot"},
            %{chat_id: 123, bot_token: "second-token", bot_name: "second-bot"}
          ],
          sender: fn
            "first-token", _message ->
              {:error, kicked}

            token, message ->
              send(parent, {:telegram_sent, token, message})
              :ok
          end
        )

      :ok = Hub.configure(load_push_router!(), telegram)

      assert {:ok, 1} =
               Hub.push("ai-token", "sticker", "sticker-file-id", nil,
                 sticker_emoji: sticker_emoji
               )

      assert_receive {:telegram_sent, "second-token",
                      %Message{
                        datatype: "sticker",
                        data: "sticker-file-id",
                        sticker_emoji: ^sticker_emoji
                      }}

      refute_receive {:telegram_sent, "first-token", _message}
    end

    test "push records successful sends before returning a later target error" do
      parent = self()

      telegram =
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "home-token"},
            %{chat_id: 456, bot_token: "work-token"}
          ],
          sender: fn
            "home-token", message ->
              send(parent, {:telegram_sent, "home-token", message})
              :ok

            "work-token", _message ->
              {:error, :telegram_unavailable}
          end
        )

      :ok = Hub.configure(load_multi_push_router!(), telegram)

      assert {:error, :telegram_unavailable} = Hub.push("ai-token", "text", "hello")
      assert_receive {:telegram_sent, "home-token", %Message{chat_id: 123, data: "hello"}}
      assert [%{kind: "push", chat_id: 123}] = Hub.status().events

      assert [
               %{
                 operation: "push",
                 hook: "assistant",
                 chat_id: 456,
                 datatype: "text",
                 preview: "hello",
                 reason: ":telegram_unavailable"
               }
             ] = Hub.status().send_failures
    end

    test "hub remains responsive while Telegram sends are in flight" do
      parent = self()

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn token, message ->
            send(parent, {:telegram_send_started, self(), token, message})

            receive do
              :release_telegram_send -> :ok
            end
          end
        )

      :ok = Hub.configure(load_push_router!(), telegram)

      caller =
        Task.async(fn ->
          Hub.push("ai-token", "text", "hello")
        end)

      assert_receive {:telegram_send_started, sender_pid, "bot-token", %Message{data: "hello"}}
      assert %{enabled: true} = Hub.status()

      send(sender_pid, :release_telegram_send)
      assert {:ok, 1} = Task.await(caller)
    end

    test "push rejects new sends when the in-flight send cap is reached" do
      :ok =
        Hub.configure(
          load_push_router!(),
          Telegram.new([%{chat_id: 123, bot_token: "bot-token"}])
        )

      :sys.replace_state(
        Hub,
        &%{
          &1
          | settings: %{&1.settings | max_in_flight_sends: 1},
            delivery: %{&1.delivery | sends: %{make_ref() => :occupied}}
        }
      )

      assert {:error, :send_queue_full} = Hub.push("ai-token", "text", "hello")
    end

    test "hung push tasks are terminated and release send capacity" do
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end}, id: make_ref())
      hub_config = Application.get_env(:exiron, :hub, [])
      Application.put_env(:exiron, :hub, Keyword.put(hub_config, :send_timeout, 20))

      on_exit(fn -> Application.put_env(:exiron, :hub, hub_config) end)

      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn token, message ->
            attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
            send(parent, {:telegram_send_started, attempt, self(), token, message})

            if attempt == 1 do
              receive do
                :never -> :ok
              end
            else
              :ok
            end
          end
        )

      :ok = Hub.configure(load_push_router!(), telegram)

      :sys.replace_state(
        Hub,
        &%{&1 | settings: %{&1.settings | max_in_flight_sends: 1}}
      )

      first = Task.async(fn -> Hub.push("ai-token", "text", "first") end)

      assert_receive {:telegram_send_started, 1, first_pid, "bot-token", %Message{data: "first"}}

      first_ref = Process.monitor(first_pid)
      assert {:error, :telegram_delivery_timeout} = Task.await(first)
      assert_receive {:DOWN, ^first_ref, :process, ^first_pid, _reason}
      assert :sys.get_state(Hub).delivery.sends == %{}

      assert {:ok, 1} = Hub.push("ai-token", "text", "second")

      assert_receive {:telegram_send_started, 2, _second_pid, "bot-token",
                      %Message{data: "second"}}
    end

    test "push returns an error when send task start fails" do
      :ok =
        Hub.configure(
          load_push_router!(),
          Telegram.new([%{chat_id: 123, bot_token: "bot-token"}])
        )

      with_send_supervisor_stopped(fn ->
        assert {:error, :send_unavailable} = Hub.push("ai-token", "text", "hello")
        assert :sys.get_state(Hub).delivery.sends == %{}
        assert Hub.status().send_capacity.bytes == 0
      end)
    end
  end
end
