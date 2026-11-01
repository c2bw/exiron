defmodule Exiron.Hub.Telegram.MembershipEventTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Telegram.MembershipEvent

  test "builds an added event and prefers the configured bot name" do
    update = %{
      old_chat_member: %{status: :left},
      new_chat_member: %{status: :member, user: %{id: 9, username: "telegram_name"}},
      chat: %{id: 7, title: "Room"}
    }

    assert MembershipEvent.from_update(update, bot_token: "secret", bot_name: "configured") ==
             %{
               action: "added",
               chat_id: 7,
               chat_title: "Room",
               bot_token: "secret",
               bot_name: "configured",
               bot_user_id: 9,
               old_status: "left",
               new_status: "member"
             }
  end

  test "accepts Telegram maps with string keys and falls back to username" do
    update = %{
      "old_chat_member" => %{"status" => "administrator"},
      "new_chat_member" => %{
        "status" => "kicked",
        "user" => %{"id" => 9, "username" => "telegram_name"}
      },
      "chat" => %{"id" => 7, "title" => "Room"}
    }

    assert %{action: "removed", bot_name: "telegram_name"} =
             MembershipEvent.from_update(update, bot_token: "secret")
  end

  test "ignores status changes that do not cross membership boundaries" do
    update = %{
      old_chat_member: %{status: "member"},
      new_chat_member: %{status: "administrator"},
      chat: %{id: 7}
    }

    refute MembershipEvent.from_update(update, bot_token: "secret")
  end
end
