defmodule Exiron.Hub.RouteConfiguration.CommandTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration.{
    ChatRouteCommand,
    HookCommand,
    MiddlewareRouteCommand,
    TelegramBotCommand,
    ValidationError
  }

  test "validation errors expose form-compatible fields and a default message" do
    error = ValidationError.new(name: "is required")
    assert ValidationError.message(error) == "is required"
    assert ValidationError.field_errors(error) == [name: {"is required", []}]
    assert ValidationError.to_form_errors(error) == [name: {"is required", []}]

    assert ValidationError.new([]).message == "configuration value is invalid"
  end

  test "hook commands normalize atom and string keyed input" do
    assert {:ok, %HookCommand{hook: "assistant", token: "secret"} = command} =
             HookCommand.new(%{"token" => " secret ", hook: " assistant "})

    assert {:ok, ^command} = HookCommand.new(command)
  end

  test "hook commands report malformed and incomplete input" do
    assert {:error, %ValidationError{}} = HookCommand.new(%{})
    assert {:error, %ValidationError{}} = HookCommand.new(:invalid)
  end

  test "Telegram bot commands normalize optional names and chat ids" do
    attrs = %{
      "bot_token" => " token ",
      "chat_id" => "-123",
      "alias" => " home ",
      "bot_name" => " helper "
    }

    assert {:ok,
            %TelegramBotCommand{
              bot_token: "token",
              chat_id: -123,
              alias: "home",
              bot_name: "helper"
            } = command} = TelegramBotCommand.new(attrs)

    assert {:ok, ^command} = TelegramBotCommand.new(command)
    assert {:error, %ValidationError{}} = TelegramBotCommand.new(%{})
    assert {:error, %ValidationError{}} = TelegramBotCommand.new(nil)
  end

  test "chat route commands normalize middleware, push, and optional bot token" do
    attrs = %{
      "alias" => " home ",
      "chat_id" => "123",
      "bot_token" => " token ",
      "middleware" => " family, alerts, family ",
      "push" => "true"
    }

    assert {:ok,
            %ChatRouteCommand{
              alias: "home",
              chat_id: 123,
              bot_token: "token",
              middleware: ["family", "alerts"],
              push: true
            }} = ChatRouteCommand.new(attrs)

    assert {:error, %ValidationError{}} = ChatRouteCommand.new(%{"alias" => "home"})
    assert {:error, %ValidationError{}} = ChatRouteCommand.new([])
  end

  test "middleware route commands require a destination and messages and normalize passthrough" do
    attrs = %{
      "middleware" => " family ",
      "hook" => " assistant ",
      "messages" => "/ai, /ask",
      "passthrough" => "true"
    }

    assert {:ok,
            %MiddlewareRouteCommand{
              middleware: "family",
              hook: "assistant",
              messages: ["/ai", "/ask"],
              passthrough: true
            }} = MiddlewareRouteCommand.new(attrs)

    assert {:error, %ValidationError{}} =
             MiddlewareRouteCommand.new(%{middleware: "family", hook: "assistant"})

    assert {:error, %ValidationError{}} = MiddlewareRouteCommand.new("invalid")
  end
end
