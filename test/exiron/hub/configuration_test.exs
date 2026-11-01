defmodule Exiron.Hub.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{Configuration, HookToken, Router}
  alias Exiron.Support.TempPath

  test "missing config file loads an empty configuration" do
    path = temp_config_path()

    assert {:ok,
            %Configuration{
              version: "1",
              telegram: [],
              aliases: %{},
              router: %Router{}
            }} = Configuration.read(path)
  end

  test "rejects non-object configuration root" do
    path = temp_config_path()
    File.write!(path, "[]")

    assert Configuration.read(path) == {:error, "configuration must be an object"}
  end

  test "rejects configuration missing version" do
    path = temp_config_path()
    File.write!(path, "{}\n")

    assert Configuration.read(path) == {:error, "configuration version is required"}
  end

  test "rejects blank configuration version" do
    path = temp_config_path()
    File.write!(path, "version: \"   \"\n")

    assert Configuration.read(path) == {:error, "configuration version is required"}
  end

  test "rejects non-string configuration version" do
    path = temp_config_path()
    File.write!(path, "version: 1\n")

    assert Configuration.read(path) == {:error, "configuration version must be a string"}
  end

  test "rejects unsupported configuration version" do
    path = temp_config_path()
    File.write!(path, "version: \"3\"\n")

    assert Configuration.read(path) == {:error, ~s(unsupported configuration version: "3")}
  end

  test "rejects plaintext hook tokens" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    hooks:
      assistant: "ai-token"
    """)

    assert Configuration.read(path) ==
             {:error, ~s(hook "assistant" token must be a sha256 digest)}
  end

  test "rejects non-list telegram bots" do
    path = temp_config_path()
    File.write!(path, "version: \"1\"\ntelegram:\n  bots: bad\n")

    assert Configuration.read(path) == {:error, "telegram.bots must be a list"}
  end

  test "rejects non-object telegram bot entries" do
    path = temp_config_path()
    File.write!(path, "version: \"1\"\ntelegram:\n  bots:\n    - bad\n")

    assert Configuration.read(path) == {:error, "telegram bot 0 must be an object"}
  end

  test "rejects structured telegram bot tokens without raising" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    telegram:
      bots:
        - token:
            nested: value
          chats: {}
    """)

    assert Configuration.read(path) ==
             {:error, "telegram bot 0 token must be a string"}
  end

  test "rejects duplicate chat aliases with conflicting IDs" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    telegram:
      bots:
        - token: one
          chats:
            home: 123
        - token: two
          chats:
            home: 456
    """)

    assert Configuration.read(path) ==
             {:error, ~s(telegram chat alias "home" has conflicting IDs)}
  end

  test "rejects duplicate bot names for one Telegram chat" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    telegram:
      bots:
        - name: helper
          token: one
          chats:
            home: 123
        - name: "@helper"
          token: two
          chats:
            home: 123
    """)

    assert Configuration.read(path) ==
             {:error, ~s(telegram bot name "helper" must be unique for chat 123)}
  end

  test "reads unified YAML and derives telegram entries and router aliases" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    telegram:
      bots:
        - name: "helper"
          token: " token "
          chats:
            home: 123
            work: 456
    routes:
      home:
        middleware:
          - shared
        push: true
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "#{HookToken.hash("ai-token")}"
    """)

    assert {:ok,
            %Configuration{
              version: "1",
              telegram: [
                %{bot_token: "token", chat_id: 123, bot_name: "helper"},
                %{bot_token: "token", chat_id: 456, bot_name: "helper"}
              ],
              aliases: %{"home" => 123, "work" => 456},
              router: %Router{}
            }} = Configuration.read(path)
  end

  test "rejects routes that reference missing Telegram chat aliases" do
    path = temp_config_path()

    File.write!(path, """
    version: "1"
    routes:
      missing:
        middleware:
          - shared
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "#{HookToken.hash("ai-token")}"
    """)

    assert Configuration.read(path) == {:error, "missing telegram alias: missing"}
  end

  defp temp_config_path do
    TempPath.tmp_path("config")
  end
end
