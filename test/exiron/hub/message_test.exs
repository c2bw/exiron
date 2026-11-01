defmodule Exiron.Hub.MessageTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Message

  test "incoming messages keep bot token, bot name, and wire instance distinct" do
    message =
      Message.incoming(222, 7, "text", "hello", bot_token: "secret", bot_name: "helper")

    assert message.bot_token == "secret"
    assert message.bot_name == "helper"
    assert message.wire_instance == "helper"
    assert Message.to_client(message, "request-1").instance == "helper"
  end

  test "outgoing messages use the explicit wire instance independently of the bot token" do
    message = Message.outgoing(222, 7, "text", "hello", "secret", bot_name: "helper")

    assert message.bot_token == "secret"
    assert message.bot_name == "helper"
    assert Message.to_listen(message).instance == "helper"
    assert Message.new(222, 7, "text", "hello", "bot-token").bot_token == "bot-token"
  end
end
