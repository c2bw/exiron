defmodule Exiron.Hub.TelegramTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.{Message, Telegram}

  setup do
    :ok = Exiron.Hub.Telegram.SendCoordinator.clear_suppression()
  end

  test "repeated definitive rejection skips the primary while preserving same-chat fallback and pinned edits" do
    parent = self()

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "rejecting-token", bot_name: "primary"},
          %{chat_id: 123, bot_token: "backup-token", bot_name: "backup"},
          %{chat_id: 456, bot_token: "rejecting-token", bot_name: "primary"}
        ],
        sender: fn token, message ->
          send(parent, {:attempt, token, message.chat_id})

          if token == "rejecting-token" and message.chat_id == 123,
            do: {:error, %ExGram.Error{code: 403}},
            else: :ok
        end
      )

    message = Message.new(222, 123, "text", "hello", "rejecting-token")
    assert {:ok, %{bot_token: "backup-token"}} = Telegram.send_message(telegram, message)
    assert_receive {:attempt, "rejecting-token", 123}
    assert_receive {:attempt, "backup-token", 123}
    assert {:ok, %{bot_token: "backup-token"}} = Telegram.send_message(telegram, message)
    assert_receive {:attempt, "backup-token", 123}
    refute_received {:attempt, "rejecting-token", 123}

    assert {:ok, %{bot_token: "rejecting-token"}} =
             Telegram.send_message(telegram, %{message | chat_id: 456})

    assert_receive {:attempt, "rejecting-token", 456}

    assert {:error, %ExGram.Error{code: 403}} =
             Telegram.send_message(telegram, %{message | edit_message_id: 901})

    refute_received {:attempt, _, _}
    assert Exiron.Hub.Telegram.SendCoordinator.snapshot().suppressed_attempts == 2
  end

  test "ambiguous failures neither suppress the bot nor fall back" do
    parent = self()

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "uncertain-primary"},
          %{chat_id: 123, bot_token: "unused-backup"}
        ],
        sender: fn token, _ ->
          send(parent, {:attempt, token})
          {:error, :timeout}
        end
      )

    for _ <- 1..2 do
      assert {:error, :timeout} =
               Telegram.send_message(
                 telegram,
                 Message.new(222, 123, "text", "hello", "uncertain-primary")
               )

      assert_receive {:attempt, "uncertain-primary"}
    end

    refute_received {:attempt, "unused-backup"}
    assert Exiron.Hub.Telegram.SendCoordinator.snapshot().active == 0
  end

  test "disabled pollers leave configured bots available for outbound messages" do
    parent = self()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    before_count = supervisor_child_count()

    assert :ok = Telegram.start_pollers(telegram, false)
    assert supervisor_child_count() == before_count

    assert {:ok, %Message{bot_token: "bot-token", data: "hello"}} =
             Telegram.send_message(telegram, Message.new(222, 123, "text", "hello"))

    assert_receive {:telegram_sent, "bot-token", %Message{data: "hello"}}
  end

  test "targeted sends fall back to another configured bot when the target bot is forbidden" do
    parent = self()
    forbidden = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "removed-token"},
          %{chat_id: 123, bot_token: "healthy-token"}
        ],
        sender: fn
          "removed-token", _message ->
            {:error, forbidden}

          token, message ->
            send(parent, {:telegram_sent, token, message})
            :ok
        end
      )

    message = Message.new(222, 123, "text", "hello", "removed-token")

    assert {:ok, %Message{bot_token: "healthy-token", data: "hello"}} =
             Telegram.send_message(telegram, message)

    assert_receive {:telegram_sent, "healthy-token", %Message{bot_token: "healthy-token"}}
  end

  test "targeted sends fall back to another configured bot when the target bot is unauthorized" do
    parent = self()
    unauthorized = %ExGram.Error{code: 401, message: "Unauthorized"}

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "bad-token"},
          %{chat_id: 123, bot_token: "healthy-token"}
        ],
        sender: fn
          "bad-token", _message ->
            {:error, unauthorized}

          token, message ->
            send(parent, {:telegram_sent, token, message})
            :ok
        end
      )

    message = Message.new(222, 123, "text", "hello", "bad-token")

    assert {:ok, %Message{bot_token: "healthy-token", data: "hello"}} =
             Telegram.send_message(telegram, message)

    assert_receive {:telegram_sent, "healthy-token", %Message{bot_token: "healthy-token"}}
  end

  test "targeted sends do not fall back across chats" do
    parent = self()
    forbidden = %ExGram.Error{code: 403, message: "Forbidden: bot was kicked from the group chat"}

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "removed-token"},
          %{chat_id: 456, bot_token: "other-chat-token"}
        ],
        sender: fn
          "removed-token", _message ->
            {:error, forbidden}

          token, message ->
            send(parent, {:telegram_sent, token, message})
            :ok
        end
      )

    assert {:error, ^forbidden} =
             Telegram.send_message(
               telegram,
               Message.new(222, 123, "text", "hello", "removed-token")
             )

    refute_receive {:telegram_sent, _token, _message}
  end

  test "named sends without a token use the named bot before the chat default" do
    parent = self()

    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "default-token", bot_name: "default-bot"},
          %{chat_id: 123, bot_token: "source-token", bot_name: "source-bot"}
        ],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    message = Message.new(222, 123, "text", "hello", nil, bot_name: "source-bot")

    assert {:ok, %Message{bot_token: "source-token", bot_name: "source-bot"}} =
             Telegram.send_message(telegram, message)

    assert_receive {:telegram_sent, "source-token", %Message{bot_name: "source-bot"}}
    refute_receive {:telegram_sent, "default-token", _message}
  end

  test "stale targeted sends fall back to the configured bot for the same chat" do
    parent = self()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "healthy-token", bot_name: "healthy-bot"}],
        sender: fn token, message ->
          send(parent, {:telegram_sent, token, message})
          :ok
        end
      )

    message = Message.new(222, 123, "text", "hello", "removed-token", bot_name: "removed-bot")

    assert {:ok, %Message{bot_token: "healthy-token", bot_name: "healthy-bot"}} =
             Telegram.send_message(telegram, message)

    assert_receive {:telegram_sent, "healthy-token", %Message{bot_name: "healthy-bot"}}
  end

  test "does not resolve missing bot names during construction" do
    telegram =
      Telegram.new(
        [
          %{chat_id: 123, bot_token: "bot-token", bot_name: nil},
          %{chat_id: 456, bot_token: "bot-token", bot_name: nil}
        ],
        bot_name_resolver: fn "bot-token" ->
          flunk("resolver should run asynchronously from the hub")
        end
      )

    refute_receive :resolved
    assert telegram |> Telegram.configs() |> Enum.map(& &1.bot_name) == [nil, nil]
  end

  test "configured bot names skip automatic lookup" do
    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: "bot-token", bot_name: "configured-bot"}],
        bot_name_resolver: fn _token ->
          flunk("resolver should not be called when bot_name is configured")
        end
      )

    assert [%{bot_name: "configured-bot"}] = Telegram.configs(telegram)
  end

  test "missing bot name tokens are unique" do
    telegram =
      Telegram.new([
        %{chat_id: 123, bot_token: "bot-token", bot_name: nil},
        %{chat_id: 456, bot_token: "bot-token", bot_name: ""},
        %{chat_id: 789, bot_token: "named-token", bot_name: "configured"}
      ])

    assert Telegram.missing_bot_name_tokens(telegram) == ["bot-token"]
  end

  defp supervisor_child_count do
    Exiron.Hub.TelegramSupervisor
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end
end
