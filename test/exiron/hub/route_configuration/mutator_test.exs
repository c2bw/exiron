defmodule Exiron.Hub.RouteConfiguration.MutatorTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration

  test "put_chat_route requires an existing Telegram bot" do
    source = """
    hooks:
      assistant: ai-token
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - /ai
    """

    assert {:error, "telegram bot is required before adding chat routes"} =
             RouteConfiguration.put_chat_route(source, %{
               "alias" => "home",
               "chat_id" => "123",
               "middleware" => "shared"
             })
  end

  test "put_chat_route adds a new alias to the only configured Telegram bot" do
    source = """
    telegram:
      bots:
        - token: bot-token
          chats:
            existing: 456
    hooks:
      assistant: ai-token
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - /ai
    """

    assert {:ok, updated} =
             RouteConfiguration.put_chat_route(source, %{
               "alias" => "home",
               "chat_id" => "123",
               "middleware" => "shared"
             })

    assert updated =~ "existing: 456"
    assert updated =~ "home: 123"
    assert updated =~ "token: \"bot-token\""
  end

  test "put_chat_route adds an alias to the bot that already owns the chat id" do
    source = """
    telegram:
      bots:
        - token: first-token
          chats:
            first: 111
        - token: second-token
          chats:
            existing: 222
    hooks:
      assistant: ai-token
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - /ai
    """

    assert {:ok, updated} =
             RouteConfiguration.put_chat_route(source, %{
               "alias" => "home",
               "chat_id" => "222",
               "middleware" => "shared"
             })

    assert normalize_newlines(updated) =~
             normalize_newlines("""
                 - token: "first-token"
                   chats:
                     first: 111
                 - token: "second-token"
                   chats:
                     existing: 222
                     home: 222
             """)
  end

  test "put_chat_route can target a bot token for a new chat" do
    source = """
    telegram:
      bots:
        - token: first-token
          chats:
            first: 111
        - token: second-token
          chats:
            existing: 222
    hooks:
      assistant: ai-token
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - /ai
    """

    assert {:ok, updated} =
             RouteConfiguration.put_chat_route(source, %{
               "alias" => "new",
               "chat_id" => "333",
               "bot_token" => "second-token",
               "middleware" => "shared"
             })

    assert normalize_newlines(updated) =~
             normalize_newlines("""
                 - token: "first-token"
                   chats:
                     first: 111
                 - token: "second-token"
                   chats:
                     existing: 222
                     new: 333
             """)
  end

  test "put_chat_route rejects ambiguous new chats when multiple bots are configured" do
    source = """
    telegram:
      bots:
        - token: first-token
          chats:
            first: 111
        - token: second-token
          chats:
            second: 222
    hooks:
      assistant: ai-token
    middlewares:
      shared:
        routes:
          assistant:
            messages:
              - /ai
    """

    assert {:error, "bot token is required when multiple Telegram bots are configured"} =
             RouteConfiguration.put_chat_route(source, %{
               "alias" => "new",
               "chat_id" => "333",
               "middleware" => "shared"
             })
  end

  test "mutations emit canonical supported sections" do
    source = """
    # Local notes are intentionally not preserved by GUI mutations.
    custom:
      keep: false
    telegram:
      bots:
        - token: bot-token
          chats:
            home: 123
    hooks:
      assistant: ai-token
    """

    assert {:ok, updated} =
             RouteConfiguration.put_hook(source, %{
               "hook" => "status",
               "token" => "status-token"
             })

    refute updated =~ "Local notes"
    refute updated =~ "custom:"

    assert String.starts_with?(
             updated,
             ~s(version: "#{Exiron.Hub.Configuration.schema_version()}"\n\n)
           )

    assert updated =~ "telegram:"
    assert updated =~ "hooks:"
    assert updated =~ ~s(assistant: "#{Exiron.Hub.HookToken.hash("ai-token")}")
    assert updated =~ ~s(status: "#{Exiron.Hub.HookToken.hash("status-token")}")
  end

  test "quotes YAML scalars that would otherwise change meaning" do
    source = """
    hooks:
      assistant: ai-token
    """

    assert {:ok, updated} =
             RouteConfiguration.put_hook(source, %{
               "hook" => "yes",
               "token" => "123:456"
             })

    assert updated =~ ~s("yes": "#{Exiron.Hub.HookToken.hash("123:456")}")
  end

  test "put_middleware_route encodes passthrough when enabled" do
    source = """
    version: "1"
    hooks:
      assistant: ai-token
    """

    assert {:ok, updated} =
             RouteConfiguration.put_middleware_route(source, %{
               "middleware" => "shared",
               "hook" => "assistant",
               "messages" => "/example",
               "passthrough" => "true"
             })

    assert normalize_newlines(updated) =~
             normalize_newlines("""
             middlewares:
               shared:
                 routes:
                   assistant:
                     messages:
                       - /example
                     passthrough: true
             """)
  end

  defp normalize_newlines(source), do: String.replace(source, "\r\n", "\n")
end
