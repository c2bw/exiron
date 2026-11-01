defmodule Exiron.Hub.RouteConfiguration.TelegramChatAliasesTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration.TelegramChatAliases

  test "requires an explicit token when multiple bots own the chat" do
    definitions = definitions([bot("first", 123), bot("second", 123)])

    assert TelegramChatAliases.put(definitions, "home", 123, nil) ==
             {:error, "bot token is required when multiple Telegram bots are configured"}
  end

  test "rejects an explicit token that is not configured" do
    definitions = definitions([bot("configured", 123)])

    assert TelegramChatAliases.put(definitions, "home", 123, "missing") ==
             {:error, "telegram bot token was not found"}
  end

  test "ignores malformed entries when one valid bot can own a new chat" do
    definitions = definitions(["invalid", bot("configured", 123)])

    assert {:ok, updated} = TelegramChatAliases.put(definitions, "new", 456, nil)

    assert get_in(updated, ["telegram", "bots"]) == [
             "invalid",
             %{"token" => "configured", "chats" => %{"existing" => 123, "new" => 456}}
           ]
  end

  defp definitions(bots), do: %{"telegram" => %{"bots" => bots}}

  defp bot(token, chat_id),
    do: %{"token" => token, "chats" => %{"existing" => chat_id}}
end
