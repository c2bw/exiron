defmodule Exiron.Hub.Status.TelegramTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{ActivityState, Router, Telegram}
  alias Exiron.Hub.Status.Telegram, as: TelegramStatus

  test "projects Telegram polling health and chat details" do
    assert {:ok, router} = Router.load_definitions(router_definitions())

    telegram =
      Telegram.new([
        %{
          chat_id: 123,
          bot_token: "first-token",
          bot_name: "first-bot",
          bot_user_id: 1
        },
        %{
          chat_id: 123,
          bot_token: "second-token",
          bot_name: "second-bot",
          bot_user_id: 2
        }
      ])

    polled_at = ~U[2026-07-15 10:00:00Z]

    state = %State{
      enabled?: true,
      router: router,
      telegram: telegram,
      telegram_pollers_enabled?: true,
      telegram_pollers: %{"first-token" => %{}, "second-token" => %{}},
      telegram_last_polled_at: polled_at,
      activity: %ActivityState{
        events: [%{chat_id: 123, bot_name: "second-bot"}],
        bot_memberships: %{
          {123, "second-token"} => membership("second-bot", 2),
          {123, "first-token"} => membership("first-bot", 1)
        }
      }
    }

    assert %{
             telegram_polling: true,
             telegram_last_polled_at: ^polled_at,
             chats: [chat]
           } = TelegramStatus.snapshot(state)

    assert chat == %{
             id: 123,
             aliases: ["home"],
             default_bot: "first-bot",
             current_bot: "second-bot",
             bot_memberships: [membership("first-bot", 1), membership("second-bot", 2)],
             polling: true,
             last_polled_at: polled_at
           }

    unavailable = %{state | telegram_pollers: Map.delete(state.telegram_pollers, "second-token")}

    assert %{telegram_polling: false, chats: [%{polling: false}]} =
             TelegramStatus.snapshot(unavailable)
  end

  defp membership(bot_name, bot_user_id) do
    %{
      chat_id: 123,
      bot_name: bot_name,
      bot_user_id: bot_user_id,
      status: "member",
      present: true
    }
  end

  defp router_definitions do
    %{
      "aliases" => %{"telegram" => %{"home" => 123}},
      "routes" => %{"home" => %{"middleware" => ["family"], "push" => true}},
      "middlewares" => %{
        "family" => %{"routes" => %{"assistant" => %{"messages" => ["/ai"]}}}
      },
      "hooks" => %{"assistant" => "ai-token"}
    }
  end
end
