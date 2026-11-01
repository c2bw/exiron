defmodule Exiron.Hub.Telegram.BotRegistryTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Telegram.BotRegistry

  test "indexes chat defaults and alternate bots" do
    registry =
      BotRegistry.new([
        %{chat_id: 123, bot_token: "primary", bot_name: "primary-bot"},
        %{chat_id: 123, bot_token: "alternate", bot_name: "alternate-bot"}
      ])

    assert BotRegistry.default_token(registry, 123) == {:ok, "primary"}
    assert BotRegistry.configured_token?(registry, 123, "alternate")
    assert BotRegistry.alternate_tokens(registry, 123, "primary") == ["alternate"]
  end

  test "preserves declaration order when deduplicating poller bots" do
    registry =
      BotRegistry.new([
        %{chat_id: 123, bot_token: "second", bot_name: nil},
        %{chat_id: 456, bot_token: "first", bot_name: "first-bot"},
        %{chat_id: 789, bot_token: "second", bot_name: "second-bot"}
      ])

    assert BotRegistry.poller_tokens(registry) == ["second", "first"]

    assert Enum.map(BotRegistry.poller_bots(registry), & &1.token) == ["second", "first"]
    assert [%{name: "second-bot"}, %{name: "first-bot"}] = BotRegistry.poller_bots(registry)
  end

  test "updates missing identity fields without replacing configured names" do
    registry =
      BotRegistry.new([
        %{chat_id: 123, bot_token: "token", bot_name: "configured"},
        %{chat_id: 456, bot_token: "token", bot_name: nil}
      ])

    registry =
      BotRegistry.put_identity(registry, "token", %{
        bot_name: "resolved",
        bot_user_id: 42
      })

    assert [first, second] = BotRegistry.configs(registry)
    assert %{bot_name: "configured", bot_user_id: 42} = first
    assert %{bot_name: "resolved", bot_user_id: 42} = second

    assert BotRegistry.config_for(registry, 456, "token") == second

    assert BotRegistry.bot_for_name(registry, 456, "resolved") ==
             {:ok, %{token: "token", name: "resolved"}}
  end

  test "normalizes bot names during chat-scoped selection" do
    registry =
      BotRegistry.new([
        %{chat_id: 123, bot_token: "token", bot_name: "helper"}
      ])

    assert BotRegistry.bot_for_name(registry, 123, " @helper ") ==
             {:ok, %{token: "token", name: "helper"}}

    assert BotRegistry.bot_for_name(registry, 456, "helper") ==
             {:error, :telegram_bot_not_configured}
  end

  test "lookup indexes preserve first-match and declaration-order semantics" do
    configs = [
      %{chat_id: 123, bot_token: "first", bot_name: "@helper"},
      %{chat_id: 123, bot_token: "second", bot_name: "helper"},
      %{chat_id: 123, bot_token: "third", bot_name: "third"},
      %{chat_id: 456, bot_token: "other", bot_name: "helper"}
    ]

    registry = BotRegistry.new(configs)

    assert BotRegistry.config_for(registry, 123, "first") == Enum.at(configs, 0)
    assert BotRegistry.config_for(registry, 123, "missing") == nil

    assert BotRegistry.bot_for_name(registry, 123, " @helper ") ==
             {:ok, %{token: "first", name: "@helper"}}

    assert BotRegistry.alternate_tokens(registry, 123, "first") == ["second", "third"]
    assert BotRegistry.alternate_tokens(registry, 123, "missing") == ["first", "second", "third"]
  end

  test "builds unique membership targets only for complete identities" do
    registry =
      BotRegistry.new([
        %{chat_id: 123, bot_token: "token", bot_name: "helper", bot_user_id: 42},
        %{chat_id: 123, bot_token: "token", bot_name: "helper", bot_user_id: 42},
        %{chat_id: 456, bot_token: "missing-id", bot_name: "other"}
      ])

    assert BotRegistry.membership_targets(registry) == [
             %{chat_id: 123, bot_token: "token", bot_name: "helper", bot_user_id: 42}
           ]
  end
end
