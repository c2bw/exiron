defmodule Exiron.Hub.LongTextTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()
    ids = start_supervised!({Agent, fn -> 900 end})

    sender = fn token, message ->
      send(parent, {:sent, token, message})
      id = message.edit_message_id || Agent.get_and_update(ids, &{&1 + 1, &1 + 1})
      {:ok, %{message_id: id}}
    end

    :ok =
      Hub.configure(
        load_push_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "one-shot long replies preserve text, topic and first-part keyboards" do
    req = request()
    text = String.duplicate("a", 4096) <> "😀tail"

    assert :ok =
             Hub.respond("ai-token", req.req_id, "text", text,
               parse_mode: "plain",
               inline_keyboard: [[%{text: "Next", callback_data: "next"}]]
             )

    assert_receive {:sent, "bot-token",
                    %{
                      data: first,
                      message_thread_id: 7,
                      inline_keyboard: [[%{callback_data: ref}]]
                    }}

    assert_receive {:sent, "bot-token",
                    %{data: second, message_thread_id: 7, inline_keyboard: nil}}

    assert first <> second == text
    assert Hub.status().delivery_health.completed_responses == 1

    assert :ok =
             Hub.incoming_callback("bot-token", %{
               id: "click",
               data: ref,
               from: %{id: 42},
               message: %{chat: %{id: 123}, message_id: 901}
             })

    {:ok, [click]} = Hub.poll("ai-token")

    assert :ok =
             Hub.respond("ai-token", click.req_id, "text", "Short",
               edit_origin: true,
               inline_keyboard: []
             )

    assert_receive {:sent, _, %{datatype: "text", edit_message_id: 901, data: "Short"}}
    assert_receive {:sent, _, %{datatype: "delete", edit_message_id: 902}}
  end

  test "streams grow, reuse message IDs, shrink, finalize and retain later editing" do
    req = request()
    assert {:ok, _} = Hub.respond("ai-token", req.req_id, "text", "start", final: false)
    assert_receive {:sent, _, %{edit_message_id: nil, data: "start"}}
    text = String.duplicate("x", 4096) <> "tail"
    assert {:ok, _} = Hub.respond("ai-token", req.req_id, "text", text, final: false)
    assert_receive {:sent, _, %{edit_message_id: 901}}
    assert_receive {:sent, _, %{edit_message_id: nil, data: "tail"}}
    assert {:ok, _} = Hub.respond("ai-token", req.req_id, "text", text <> "!", final: false)
    assert_receive {:sent, _, %{edit_message_id: 901}}
    assert_receive {:sent, _, %{edit_message_id: 902, data: "tail!"}}
    assert :ok = Hub.respond("ai-token", req.req_id, "text", text <> " done")
    assert_receive {:sent, _, %{edit_message_id: 901}}
    assert_receive {:sent, _, %{edit_message_id: 902, data: "tail done"}}
    assert :ok = Hub.edit("ai-token", req.req_id, "text", "shorter")
    assert_receive {:sent, _, %{edit_message_id: 901, data: "shorter"}}
    assert_receive {:sent, _, %{datatype: "delete", edit_message_id: 902}}
    refute_receive {:sent, _, _}
  end

  test "push counts chats rather than text parts" do
    assert {:ok, 1} =
             Hub.push("ai-token", "text", String.duplicate("x", 8193), 123,
               parse_mode: "plain",
               message_thread_id: 9
             )

    for _ <- 1..3 do
      assert_receive {:sent, _, %{message_thread_id: 9}}
    end
  end

  test "a later-part auth failure never retries the whole response or changes bots" do
    parent = self()

    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: "bot-token"}, %{chat_id: 123, bot_token: "backup"}],
        sender: fn token, message ->
          send(parent, {:attempt, token, message.data})

          if String.length(message.data) == 4096,
            do: {:ok, %{message_id: 901}},
            else: {:error, %ExGram.Error{code: 401}}
        end
      )

    :ok = Hub.configure(load_push_router!(), telegram)
    {:ok, []} = Hub.poll("ai-token")
    req = request()

    assert {:error, :telegram_delivery_timeout} =
             Hub.respond("ai-token", req.req_id, "text", String.duplicate("x", 4097),
               parse_mode: "plain"
             )

    assert_receive {:attempt, "bot-token", _}
    assert_receive {:attempt, "bot-token", "x"}
    refute_receive {:attempt, "backup", _}
    assert {:error, :request_not_found} = Hub.respond("ai-token", req.req_id, "text", "retry")
  end

  test "an uncertain growing edit invalidates its receipt to prevent duplicate appended parts" do
    req = request()
    :ok = Hub.respond("ai-token", req.req_id, "text", "short")
    assert_receive {:sent, _, _}

    :sys.replace_state(Hub, fn state ->
      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, message ->
            if message.edit_message_id,
              do: {:ok, %{message_id: message.edit_message_id}},
              else: {:error, %ExGram.Error{code: :transport_error}}
          end
        )

      %{state | telegram: telegram}
    end)

    assert {:error, :telegram_delivery_timeout} =
             Hub.edit("ai-token", req.req_id, "text", String.duplicate("x", 4097))

    assert {:error, :request_not_found} = Hub.edit("ai-token", req.req_id, "text", "retry")
  end

  test "an exception after a visible part closes the request without replay" do
    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, message ->
          if byte_size(message.data) == 4096,
            do: {:ok, %{message_id: 901}},
            else: raise("sender failed")
        end
      )

    :ok = Hub.configure(load_push_router!(), telegram)
    {:ok, []} = Hub.poll("ai-token")
    req = request()

    assert {:error, :telegram_delivery_timeout} =
             Hub.respond("ai-token", req.req_id, "text", String.duplicate("x", 4097),
               parse_mode: "plain"
             )

    assert {:error, :request_not_found} = Hub.respond("ai-token", req.req_id, "text", "retry")
  end

  test "rate limiting retries only the rejected part" do
    parent = self()
    attempts = start_supervised!({Agent, fn -> 0 end}, id: :attempts)

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _, message ->
          send(parent, {:attempt, byte_size(message.data)})

          if byte_size(message.data) == 4096 do
            {:ok, %{message_id: 901}}
          else
            attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})

            if attempt == 0,
              do:
                {:error, %ExGram.Error{code: 429, metadata: %{parameters: %{"retry_after" => 1}}}},
              else: {:ok, %{message_id: 902}}
          end
        end
      )

    :ok = Hub.configure(load_push_router!(), telegram)
    {:ok, []} = Hub.poll("ai-token")
    req = request()

    assert :ok =
             Hub.respond("ai-token", req.req_id, "text", String.duplicate("x", 4097),
               parse_mode: "plain"
             )

    assert_receive {:attempt, 4096}
    assert_receive {:attempt, 1}
    assert_receive {:attempt, 1}
    refute_receive {:attempt, _}
  end

  defp request do
    :ok =
      Hub.incoming_service_message(
        Message.incoming(222, 123, "text", "/ai request",
          bot_token: "bot-token",
          message_thread_id: 7
        )
      )

    {:ok, [req]} = Hub.poll("ai-token")
    req
  end
end
