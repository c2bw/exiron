defmodule Exiron.OTPStatusTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub

  alias Exiron.Hub.{
    ActivityState,
    BotLookupTasks,
    Configuration,
    DeliveryState,
    EventMediaStore,
    Message,
    QueueBuffer,
    RouteConfiguration,
    Router,
    Telegram
  }

  alias Exiron.Hub.Telegram.{Poller, PollerState}
  alias Exiron.Secret

  test "sensitive runtime structs have safe inspection output" do
    hook_secret = "hook-secret-77fbcab1"
    bot_secret = "bot-secret-17db65cb"
    payload_secret = "payload-secret-85c669f0"

    router = %Router{hooks: %{"assistant" => hook_secret}}

    telegram =
      Telegram.new([
        %{chat_id: 123, bot_token: bot_secret, bot_name: "assistant-bot"}
      ])

    message = Message.new(222, 123, "text", payload_secret, bot_secret)

    configuration = %Configuration{
      telegram: [%{chat_id: 123, bot_token: bot_secret}],
      router: router,
      definitions: %{"hooks" => %{"assistant" => hook_secret}},
      aliases: %{"main" => 123}
    }

    route_configuration = %RouteConfiguration{
      path: "routes.yml",
      source: "hooks:\n  assistant: #{hook_secret}\n",
      configuration: configuration,
      router: router,
      bots: [%{token: bot_secret}]
    }

    hub = %State{
      enabled?: true,
      router: router,
      telegram: telegram,
      delivery: %DeliveryState{
        pending: %{"request-1" => %{bot_token: bot_secret, message: message}},
        sends: %{make_ref() => {nil, {:push, "assistant", message}}}
      }
    }

    poller = %PollerState{
      token: bot_secret,
      bot_name: "assistant-bot",
      get_updates: fn _opts -> {:ok, []} end
    }

    terms = [
      Secret.new(bot_secret),
      router,
      telegram,
      message,
      configuration,
      route_configuration,
      hub,
      poller
    ]

    Enum.each(terms, fn term ->
      inspected = inspect(term)

      refute inspected =~ hook_secret
      refute inspected =~ bot_secret
      refute inspected =~ payload_secret
    end)
  end

  test "hub crash status removes secrets from state, message, reason, and debug log" do
    configured_secret = "configured-secret-05e8e23a"
    attempted_secret = "attempted-secret-68b08746"
    reason_secret = "reason-secret-663059bd"
    log_secret = "log-secret-c926215a"

    state = %State{
      enabled?: true,
      telegram_pollers_enabled?: true,
      router: %Router{hooks: %{"assistant" => configured_secret}},
      telegram: Telegram.new([%{chat_id: 123, bot_token: configured_secret, bot_name: "bot"}]),
      telegram_pollers: %{configured_secret => %{pid: self(), monitor: make_ref()}},
      delivery: %DeliveryState{
        queues: %{"assistant" => QueueBuffer.from_items([%{data: configured_secret}])},
        clients: %{{"assistant", "client"} => %{pid: self()}},
        pending: %{"request" => %{bot_token: configured_secret}},
        sends: %{make_ref() => configured_secret}
      },
      activity: %ActivityState{
        events: [%{preview: configured_secret}],
        client_events: [%{reason: configured_secret}]
      }
    }

    status =
      Hub.format_status(%{
        state: state,
        message:
          {:"$gen_call", {self(), make_ref()}, {:authenticate, Secret.new(attempted_secret)}},
        reason: %RuntimeError{message: reason_secret},
        log: [{:in, log_secret}]
      })

    assert status.state == %{
             enabled?: true,
             telegram_pollers_enabled?: true,
             telegram_pollers: 1,
             queues: 1,
             clients: 1,
             pending: 1,
             sends: 1,
             events: 1,
             client_events: 1
           }

    assert status.message == {:call, :authenticate}
    assert status.reason == {:exception, RuntimeError}
    assert status.log == []

    report = inspect(status)
    refute report =~ configured_secret
    refute report =~ attempted_secret
    refute report =~ reason_secret
    refute report =~ log_secret
  end

  test "Telegram poller status and supervisor child specs redact bot tokens" do
    bot_secret = "bot-secret-c9836597"
    message_secret = "message-secret-6971cbc9"
    reason_secret = "reason-secret-e47658a3"

    state = %PollerState{
      token: bot_secret,
      bot_name: "assistant-bot",
      offset: 42,
      max_download_bytes: 1_024,
      empty_poll_delay: 100
    }

    status =
      Poller.format_status(%{
        state: state,
        message: {:"$gen_cast", {:put_bot_name, bot_secret, message_secret}},
        reason: {:telegram_error, reason_secret},
        log: [{:in, bot_secret}]
      })

    assert status.state == %{
             bot_name: "assistant-bot",
             offset: 42,
             max_download_bytes: 1_024,
             empty_poll_delay: 100
           }

    assert status.message == {:cast, :put_bot_name}
    assert status.reason == :telegram_error
    assert status.log == []

    child_spec = Poller.child_spec(token: bot_secret, bot_name: "assistant-bot")
    assert {Poller, :start_link, [protected_opts]} = child_spec.start
    assert %Secret{} = Keyword.fetch!(protected_opts, :token)

    report = inspect({status, child_spec})
    refute report =~ bot_secret
    refute report =~ message_secret
    refute report =~ reason_secret
  end

  test "media store and lookup dispatcher statuses redact retained payloads and tokens" do
    media_secret = "media-secret-cf796eb2"
    bot_secret = "bot-secret-4e280fc9"

    media_status =
      EventMediaStore.format_status(%{
        state: %EventMediaStore{
          entries: %{
            "media-id" => %{
              bytes: media_secret,
              mime_type: "image/png",
              scope: {:hook, "assistant"},
              size: byte_size(media_secret)
            }
          },
          bytes: byte_size(media_secret),
          max_bytes: 1_024
        },
        message: {:"$gen_call", {self(), make_ref()}, {:fetch, "media-id", :dashboard}},
        reason: {:media_error, media_secret},
        log: [{:in, media_secret}]
      })

    lookup_status =
      BotLookupTasks.format_status(%{
        state: %{
          queue: :queue.from_list([%{item: bot_secret}]),
          active: %{self() => %{item: bot_secret}},
          max_concurrency: 2,
          max_queue: 3
        },
        message: {:"$gen_call", {self(), make_ref()}, {:enqueue, self(), [bot_secret]}},
        reason: {:lookup_error, bot_secret},
        log: [{:in, bot_secret}]
      })

    assert media_status.state == %{entries: 1, bytes: byte_size(media_secret), max_bytes: 1_024}
    assert lookup_status.state == %{queued: 1, active: 1, max_concurrency: 2, max_queue: 3}

    report = inspect({media_status, lookup_status})
    refute report =~ media_secret
    refute report =~ bot_secret
  end
end
