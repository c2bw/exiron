defmodule Exiron.Hub.ReplyContextTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{MediaAlbum, Message, Telegram}

  setup do
    parent = self()
    ids = start_supervised!({Agent, fn -> 900 end})
    router = load_push_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "helper"}],
          sender: fn token, message ->
            send(parent, {:sent, token, message})

            {:ok,
             %{
               message_id: message.edit_message_id || Agent.get_and_update(ids, &{&1 + 1, &1 + 1})
             }}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "default replies stay unrelated while opt-in targets the incoming message itself" do
    req = request(10)
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "default")
    assert_receive {:sent, _, %{reply_to_message_id: nil, message_thread_id: 7}}
    req = request(11)
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "anchored", reply_to_original: true)
    assert_receive {:sent, _, %{reply_to_message_id: 11, message_thread_id: 7}}
    # The incoming message itself replied to 5; that parent must not become our target.
    assert req.reply_to_message_id == 5
  end

  test "multipart replies attach the reference only to the first part" do
    req = request(10)

    assert :ok =
             Hub.respond("ai-token", req.req_id, "text", String.duplicate("x", 8193),
               reply_to_original: true,
               parse_mode: "plain"
             )

    assert_receive {:sent, _, %{reply_to_message_id: 10, message_thread_id: 7}}
    assert_receive {:sent, _, %{reply_to_message_id: nil, message_thread_id: 7}}
    assert_receive {:sent, _, %{reply_to_message_id: nil, message_thread_id: 7}}
  end

  test "streams retain context when options are omitted and do not anchor continuation parts" do
    req = request(10)

    assert {:ok, _} =
             Hub.respond("ai-token", req.req_id, "text", "partial",
               final: false,
               reply_to_original: true
             )

    assert_receive {:sent, _, %{reply_to_message_id: 10, edit_message_id: nil}}

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "text", "changed",
               final: false,
               reply_to_original: false
             )

    text = String.duplicate("x", 4096) <> "tail"
    assert {:ok, _} = Hub.respond("ai-token", req.req_id, "text", text, final: false)
    assert_receive {:sent, _, %{edit_message_id: 901, reply_to_message_id: 10}}
    assert_receive {:sent, _, %{edit_message_id: nil, reply_to_message_id: nil, data: "tail"}}
    assert :ok = Hub.respond("ai-token", req.req_id, "text", text <> " done")
    assert_receive {:sent, _, %{edit_message_id: 901, reply_to_message_id: 10}}
    assert_receive {:sent, _, %{edit_message_id: 902, reply_to_message_id: nil}}
    assert :ok = Hub.edit("ai-token", req.req_id, "text", "shorter")
    assert_receive {:sent, _, %{edit_message_id: 901, reply_to_message_id: 10}}

    assert_receive {:sent, _,
                    %{datatype: "delete", edit_message_id: 902, reply_to_message_id: nil}}

    assert {:error, :invalid_payload} =
             Hub.edit("ai-token", req.req_id, "text", "retarget", reply_to_original: true)
  end

  test "an unrelated stream cannot acquire a reply reference after its first message" do
    req = request(10)
    {:ok, _} = Hub.respond("ai-token", req.req_id, "text", "partial", final: false)
    assert_receive {:sent, _, %{reply_to_message_id: nil}}

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "text", "retarget", reply_to_original: true)

    assert :ok = Hub.respond("ai-token", req.req_id, "text", "done")
    assert_receive {:sent, _, %{reply_to_message_id: nil}}
  end

  test "missing source IDs and invalid flags leave requests available" do
    for {id, opts} <- [
          {nil, [reply_to_original: true]},
          {0, [reply_to_original: true]},
          {12, [reply_to_original: "true"]}
        ] do
      req = request(id)

      assert {:error, :invalid_payload} =
               Hub.respond("ai-token", req.req_id, "text", "reply", opts)

      assert :ok = Hub.respond("ai-token", req.req_id, "text", "default")
      assert_receive {:sent, _, %{reply_to_message_id: nil}}
    end
  end

  test "media, stickers and albums retain source and topic context" do
    album =
      MediaAlbum.encode([
        %{datatype: "image", data: "photo"},
        %{datatype: "video", data: "video"}
      ])

    for {type, data, id} <- [
          {"file", "bytes", 10},
          {"sticker", "sticker-id", 11},
          {"album", album, 12}
        ] do
      req = request(id)
      assert :ok = Hub.respond("ai-token", req.req_id, type, data, reply_to_original: true)

      assert_receive {:sent, _,
                      %{datatype: ^type, reply_to_message_id: ^id, message_thread_id: 7}}
    end
  end

  test "ownership is checked and pushes have no original request context" do
    req = request(10)

    assert {:error, :request_not_assigned} =
             Hub.respond("other-token", req.req_id, "text", "stolen", reply_to_original: true)

    assert {:error, :invalid_payload} =
             Hub.push("ai-token", "text", "push", 123, reply_to_original: true)

    refute_receive {:sent, _, _}

    assert :ok =
             Hub.respond("ai-token", req.req_id, "text", "legitimate", reply_to_original: true)
  end

  test "a callback can reply to its clicked message, but cannot retarget an origin edit" do
    req = request(10)

    :ok =
      Hub.respond("ai-token", req.req_id, "text", "menu",
        inline_keyboard: [[%{text: "Next", callback_data: "next"}]]
      )

    assert_receive {:sent, _, %{inline_keyboard: [[%{callback_data: ref}]]}}

    query = %{
      id: "click-1",
      data: ref,
      from: %{id: 42},
      message: %{chat: %{id: 123}, message_id: 901}
    }

    :ok = Hub.incoming_callback("bot-token", query)
    {:ok, [click]} = Hub.poll("ai-token")

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", click.req_id, "text", "edit",
               edit_origin: true,
               reply_to_original: true
             )

    assert :ok =
             Hub.respond("ai-token", click.req_id, "text", "new reply", reply_to_original: true)

    assert_receive {:sent, _,
                    %{reply_to_message_id: 901, edit_message_id: nil, message_thread_id: 7}}
  end

  test "bot fallback preserves the same reply target" do
    parent = self()

    :sys.replace_state(Hub, fn state ->
      %{
        state
        | telegram:
            Telegram.new(
              [
                %{chat_id: 123, bot_token: "bot-token"},
                %{chat_id: 123, bot_token: "backup-token"}
              ],
              sender: fn token, message ->
                send(
                  parent,
                  {:attempt, token, message.reply_to_message_id, message.message_thread_id}
                )

                if token == "bot-token",
                  do: {:error, %ExGram.Error{code: 401}},
                  else: {:ok, %{message_id: 901}}
              end
            )
      }
    end)

    req = request(10)
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "reply", reply_to_original: true)
    assert_receive {:attempt, "bot-token", 10, 7}
    assert_receive {:attempt, "backup-token", 10, 7}
  end

  defp request(id) do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "bot-token",
          message_id: id,
          reply_to_message_id: 5,
          message_thread_id: 7
        )
      )

    {:ok, [req]} = Hub.poll("ai-token")
    req
  end
end
