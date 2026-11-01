defmodule Exiron.Hub.RouteConfiguration.CommandsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration.ChatRouteCommand
  alias Exiron.Hub.RouteConfiguration.HookCommand
  alias Exiron.Hub.RouteConfiguration.MiddlewareRouteCommand
  alias Exiron.Hub.RouteConfiguration.TelegramBotCommand
  alias Exiron.Hub.RouteConfiguration.ValidationError

  test "telegram bot command coerces values and ignores unknown fields" do
    assert {:ok,
            %TelegramBotCommand{
              bot_token: "bot-token",
              chat_id: 123,
              alias: "home",
              bot_name: "Support"
            }} =
             TelegramBotCommand.new(%{
               "bot_token" => "  bot-token ",
               "chat_id" => "123",
               "alias" => " home ",
               "bot_name" => " Support ",
               "unknown" => "ignored"
             })
  end

  test "chat route command normalizes middleware and push values" do
    assert {:ok,
            %ChatRouteCommand{
              alias: "home",
              chat_id: 123,
              bot_token: nil,
              middleware: ["shared", "family"],
              push: true
            }} =
             ChatRouteCommand.new(%{
               "alias" => "home",
               "chat_id" => 123,
               "middleware" => "shared, family\nshared",
               "push" => "on"
             })
  end

  test "validation errors retain all fields for form adapters" do
    assert {:error, %ValidationError{} = error} =
             MiddlewareRouteCommand.new(%{"middleware" => "", "hook" => "", "messages" => ""})

    assert error.errors == %{
             middleware: "middleware is required",
             hook: "hook is required",
             messages: "messages are required"
           }

    assert ValidationError.message(error) == "middleware is required"
    assert {:middleware, {"middleware is required", []}} in ValidationError.to_form_errors(error)
  end

  test "all edit types are typed and accept atom-keyed parameters" do
    assert {:ok, %TelegramBotCommand{}} =
             TelegramBotCommand.new(%{bot_token: "token", chat_id: "1", alias: "home"})

    assert {:ok, %ChatRouteCommand{}} =
             ChatRouteCommand.new(%{alias: "home", chat_id: "1"})

    assert {:ok, %MiddlewareRouteCommand{messages: ["/start"]}} =
             MiddlewareRouteCommand.new(%{
               middleware: "shared",
               hook: "assistant",
               messages: "/start"
             })

    assert {:ok, %HookCommand{hook: "assistant", token: "secret"}} =
             HookCommand.new(%{hook: "assistant", token: "secret"})
  end
end
