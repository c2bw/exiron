defmodule Exiron.Hub.StatusTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.State

  alias Exiron.Hub.{ActivityState, DeliveryState, QueueBuffer, Router, Status, Telegram}

  test "reports Telegram polling as unhealthy when no bots are configured" do
    assert {:ok, router} = Router.load_definitions(%{})

    state = %State{
      enabled?: true,
      telegram_pollers_enabled?: true,
      router: router,
      telegram: Telegram.new([])
    }

    refute Status.snapshot(state, "test").telegram_polling
  end

  test "projects hook status directly without leaking another hook or chat" do
    assert {:ok, router} = Router.load_definitions(router_definitions())

    state = %State{
      enabled?: true,
      router: router,
      health: %{
        "assistant" => %{Exiron.Hub.DeliveryHealth.empty() | unavailable_rejections: 2},
        "powerwall" => %{Exiron.Hub.DeliveryHealth.empty() | unavailable_rejections: 99}
      },
      telegram: Telegram.new(telegram_configs()),
      telegram_pollers_enabled?: true,
      telegram_pollers: %{"first-token" => %{}, "second-token" => %{}, "unrelated" => %{}},
      telegram_last_polled_at: ~U[2026-07-15 10:00:00Z],
      delivery: %DeliveryState{
        clients: %{"assistant" => %{listen?: true}, "powerwall" => %{listen?: true}},
        queues: %{
          "assistant" => QueueBuffer.from_items([:queued]),
          "powerwall" => QueueBuffer.from_items([:unrelated])
        },
        pending: %{
          "assistant-request" => %{hook: "assistant"},
          "powerwall-request" => %{hook: "powerwall"}
        }
      },
      activity: %ActivityState{
        events: [%{hook: "assistant", chat_id: 123}, %{hook: "powerwall", chat_id: 456}],
        send_failures: [%{hook: "assistant"}, %{hook: "powerwall"}],
        overload_events: [%{hook: "assistant"}, %{hook: "powerwall"}],
        membership_events: [%{chat_id: 123}, %{chat_id: 456}],
        bot_memberships: %{
          {123, "first-token"} => %{chat_id: 123, bot_name: "first", bot_user_id: 1},
          {456, "second-token"} => %{chat_id: 456, bot_name: "second", bot_user_id: 2}
        },
        client_events: [%{hook: "assistant"}, %{hook: "powerwall"}]
      }
    }

    status = Status.snapshot_for_hook(state, "test", "assistant")

    assert status.requested == 1

    assert [%{name: "assistant", connected: true, listening: true, queued: 1, health: health}] =
             status.hooks

    assert health.pending == 1
    assert status.delivery_health.pending == 1
    assert status.delivery_health.unavailable_rejections == 2
    assert Enum.map(status.routes, & &1.to) == ["assistant"]
    assert Enum.map(status.chats, & &1.id) == [123]
    assert status.telegram_polling
    assert status.telegram_last_polled_at == nil
    assert Enum.all?(status.events, &(&1.hook == "assistant"))
    assert Enum.all?(status.send_failures, &(&1.hook == "assistant"))
    assert Enum.all?(status.overload_events, &(&1.hook == "assistant"))
    assert Enum.all?(status.client_events, &(&1.hook == "assistant"))
    assert Enum.all?(status.membership_events, &(&1.chat_id == 123))
    assert Enum.all?(status.bot_memberships, &(&1.chat_id == 123))
    refute Enum.any?(status.routes, &(&1.to == "powerwall"))
    refute Enum.any?(status.chats, &(&1.id == 456))
  end

  defp router_definitions do
    %{
      "aliases" => %{"telegram" => %{"home" => 123, "status" => 456}},
      "routes" => %{
        "home" => %{"middleware" => ["family"], "push" => true},
        "status" => %{"middleware" => ["status"]}
      },
      "middlewares" => %{
        "family" => %{
          "routes" => %{
            "assistant" => %{"messages" => ["/ai"]}
          }
        },
        "status" => %{
          "routes" => %{
            "powerwall" => %{"messages" => ["/power"]}
          }
        }
      },
      "hooks" => %{"assistant" => "ai-token", "powerwall" => "power-token"}
    }
  end

  defp telegram_configs do
    [
      %{chat_id: 123, bot_token: "first-token", bot_name: "first"},
      %{chat_id: 456, bot_token: "second-token", bot_name: "second"},
      %{chat_id: 789, bot_token: "unrelated", bot_name: "unrelated"}
    ]
  end
end
