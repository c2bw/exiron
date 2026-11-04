defmodule Exiron.Hub.MessageTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Message

  test "sticker file identity survives request and listen JSON serialization" do
    for unique_id <- ["unique-sticker", nil] do
      message =
        Message.incoming(222, 123, "file", "sticker bytes",
          sticker_id: "sendable-file-id",
          file_unique_id: unique_id
        )

      for payload <- [Message.to_client(message, "request-1"), Message.to_listen(message)] do
        wire = payload |> Jason.encode!() |> Jason.decode!()
        assert wire["file_unique_id"] == unique_id
        assert wire["sticker_id"] == "sendable-file-id"
        assert Base.decode64!(wire["data"]) == "sticker bytes"
      end
    end
  end

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
