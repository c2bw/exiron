defmodule Exiron.Hub.Configuration.BotParserTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Configuration.BotParser

  test "parses bots and derives aliases in definition order" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{"token" => " first ", "name" => " helper ", "chats" => %{"home" => 123}},
          %{"token" => "second", "chats" => %{"work" => 456}}
        ]
      }
    }

    assert {:ok,
            {[
               %{bot_token: "first", bot_name: "helper", chat_id: 123},
               %{bot_token: "second", bot_name: nil, chat_id: 456}
             ], %{"home" => 123, "work" => 456}}} = BotParser.parse(definitions)
  end

  test "allows aliases shared by bots when their chat ID agrees" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{"token" => "first", "chats" => %{"home" => 123}},
          %{"token" => "second", "chats" => %{"home" => 123}}
        ]
      }
    }

    assert {:ok, {[_first, _second], %{"home" => 123}}} = BotParser.parse(definitions)
  end

  test "rejects structured bot string fields" do
    for {field, value, reason} <- [
          {"token", %{"nested" => "value"}, "telegram bot 0 token must be a string"},
          {"name", ["helper"], "telegram bot 0 name must be a string"}
        ] do
      definitions = %{
        "telegram" => %{
          "bots" => [%{"token" => "secret", "chats" => %{"home" => 123}, field => value}]
        }
      }

      assert BotParser.parse(definitions) == {:error, reason}
    end
  end

  test "rejects non-string chat aliases" do
    definitions = %{
      "telegram" => %{
        "bots" => [%{"token" => "secret", "chats" => %{["home"] => 123}}]
      }
    }

    assert BotParser.parse(definitions) ==
             {:error, "telegram bot 0 chat aliases must be strings"}
  end

  test "rejects duplicate normalized bot names in the same chat" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{"token" => "first", "name" => "helper", "chats" => %{"home" => 123}},
          %{"token" => "second", "name" => " @helper ", "chats" => %{"home" => 123}}
        ]
      }
    }

    assert BotParser.parse(definitions) ==
             {:error, ~s(telegram bot name "helper" must be unique for chat 123)}
  end

  test "allows the same normalized bot name in different chats" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{"token" => "first", "name" => "helper", "chats" => %{"home" => 123}},
          %{"token" => "second", "name" => "@helper", "chats" => %{"work" => 456}}
        ]
      }
    }

    assert {:ok, {[_first, _second], %{"home" => 123, "work" => 456}}} =
             BotParser.parse(definitions)
  end

  test "allows one named bot to reference a chat through multiple aliases" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{
            "token" => "shared",
            "name" => "helper",
            "chats" => %{"family" => 123, "home" => 123}
          }
        ]
      }
    }

    assert {:ok, {[_first, _second], %{"family" => 123, "home" => 123}}} =
             BotParser.parse(definitions)
  end

  test "rejects conflicting aliases" do
    definitions = %{
      "telegram" => %{
        "bots" => [
          %{"token" => "first", "chats" => %{"home" => 123}},
          %{"token" => "second", "chats" => %{"home" => 456}}
        ]
      }
    }

    assert BotParser.parse(definitions) ==
             {:error, ~s(telegram chat alias "home" has conflicting IDs)}
  end
end
