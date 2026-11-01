defmodule Exiron.Hub.RouteConfiguration.TelegramProjectionTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration.TelegramProjection
  alias Exiron.Hub.Telegram

  test "builds stable bot and chat summaries" do
    configs = [
      bot("zeta-secret", 30, "zeta-bot"),
      bot("alpha-secret", 20, "alpha-bot"),
      bot("alpha-secret", 10, nil),
      bot("alpha-secret", 10, nil)
    ]

    aliases = %{"zeta" => 20, "home" => 10, "alpha" => 20, "other" => 30}

    assert [alpha, zeta] = TelegramProjection.bots(configs, aliases)

    assert alpha == %{
             id: 1,
             chats: [
               %{id: 10, aliases: ["home"]},
               %{id: 20, aliases: ["alpha", "zeta"]}
             ],
             chat_aliases: ["alpha", "home", "zeta"],
             chat_ids: [10, 20],
             chat_count: 2,
             bot_name: "alpha-bot",
             bot_tag: "@alpha-bot",
             bot_tag_source: :config,
             token_fingerprint: Telegram.token_fingerprint("alpha-secret")
           }

    assert zeta == %{
             id: 2,
             chats: [%{id: 30, aliases: ["other"]}],
             chat_aliases: ["other"],
             chat_ids: [30],
             chat_count: 1,
             bot_name: "zeta-bot",
             bot_tag: "@zeta-bot",
             bot_tag_source: :config,
             token_fingerprint: Telegram.token_fingerprint("zeta-secret")
           }
  end

  test "returns no summaries when no bots are configured" do
    assert TelegramProjection.bots([], %{"unused" => 123}) == []
  end

  defp bot(token, chat_id, name) do
    %{bot_token: token, chat_id: chat_id, bot_name: name}
  end
end
