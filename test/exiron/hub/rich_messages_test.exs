defmodule Exiron.Hub.RichMessagesTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  setup do
    parent = self()
    router = load_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "helper"}],
        sender: fn _token, message ->
          send(parent, {:sent, message})

          if message.datatype == "action",
            do: :ok,
            else: {:ok, %{message_id: message.edit_message_id || 901}}
        end
      )

    :ok = Hub.configure(router, telegram)
    :ok
  end

  test "one-shot remains the default, while partial updates edit and finalize explicitly" do
    req = request(message_thread_id: 7)
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "one shot")

    assert_receive {:sent,
                    %{data: "one shot", final?: true, edit_message_id: nil, message_thread_id: 7}}

    assert Hub.status().delivery_health.pending == 0

    req = request(message_thread_id: 7)

    assert {:ok, %{ok: true, final: false, message_id: 901}} =
             Hub.respond("ai-token", req.req_id, "text", "Hel", final: false)

    assert_receive {:sent,
                    %{
                      data: "Hel",
                      final?: false,
                      edit_message_id: nil,
                      parse_mode: "plain",
                      message_thread_id: 7
                    }}

    assert Hub.request_trace(req.req_id).status == :awaiting_response
    assert Hub.status().delivery_health.pending == 1
    assert Hub.status().delivery_health.completed_responses == 1

    assert {:ok, %{final: false}} =
             Hub.respond("ai-token", req.req_id, "text", "Hello", final: false)

    assert_receive {:sent, %{data: "Hello", edit_message_id: 901}}
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "Hello world")

    assert_receive {:sent,
                    %{
                      data: "Hello world",
                      final?: true,
                      edit_message_id: 901,
                      parse_mode: "plain"
                    }}

    assert Hub.status().delivery_health.pending == 0
    assert Hub.status().delivery_health.completed_responses == 2
    assert Hub.request_trace(req.req_id).status == :completed
    assert {:error, :request_not_found} = Hub.respond("ai-token", req.req_id, "text", "again")
  end

  test "completed text replies can be edited only by their owning hook" do
    req = request()
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "original")
    assert_receive {:sent, %{data: "original"}}
    assert {:error, :request_not_assigned} = Hub.edit("other-token", req.req_id, "text", "stolen")
    assert :ok = Hub.edit("ai-token", req.req_id, "text", "corrected")
    assert_receive {:sent, %{data: "corrected", edit_message_id: 901}}
    assert Hub.status().delivery_health.completed_responses == 1
    assert {:error, :request_not_found} = Hub.edit("ai-token", "missing", "text", "text")
  end

  test "typing actions inherit the request topic and do not consume it" do
    req = request(message_thread_id: 11)
    assert :ok = Hub.action("ai-token", req.req_id, "typing")
    assert_receive {:sent, %{datatype: "action", data: "typing", message_thread_id: 11}}
    assert Hub.status().delivery_health.pending == 1
    assert Hub.status().delivery_health.completed_responses == 0
    assert {:error, :request_not_assigned} = Hub.action("other-token", req.req_id, "typing")
    assert {:error, :invalid_payload} = Hub.action("ai-token", req.req_id, "invalid")
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "done")
    assert {:error, :request_not_found} = Hub.action("ai-token", req.req_id, "typing")
  end

  test "invalid new options leave existing requests available" do
    req = request()

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "file", "bytes", final: false)

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "text", "x", final: "false")

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "text", "x",
               entities: [%{"type" => "bold", "offset" => 0, "length" => 99}]
             )

    assert Hub.status().delivery_health.pending == 1
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "done")
  end

  test "streaming preserves the original expiry deadline" do
    req = request()
    assert {:ok, _} = Hub.respond("ai-token", req.req_id, "text", "partial", final: false)
    send(Hub, {:expire_request, req.req_id})
    assert Hub.request_trace(req.req_id).status == :expired
    assert {:error, :request_not_found} = Hub.respond("ai-token", req.req_id, "text", "too late")
  end

  test "simultaneous updates cannot create duplicate provisional replies" do
    parent = self()

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
        sender: fn _token, _message ->
          send(parent, {:send_started, self()})

          receive do
            :release -> {:ok, %{message_id: 901}}
          end
        end
      )

    :ok = Hub.configure(load_router!(), telegram)
    req = request()

    caller =
      start_supervised!(
        {Task,
         fn ->
           send(
             parent,
             {:result, Hub.respond("ai-token", req.req_id, "text", "partial", final: false)}
           )
         end}
      )

    ref = Process.monitor(caller)
    assert_receive {:send_started, sender}

    assert {:error, :request_in_flight} =
             Hub.respond("ai-token", req.req_id, "text", "duplicate", final: false)

    assert {:error, :request_in_flight} = Hub.action("ai-token", req.req_id, "typing")
    send(sender, :release)
    assert_receive {:result, {:ok, %{final: false}}}
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
  end

  test "editing never falls back to a different bot" do
    parent = self()

    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: "bot-token"}, %{chat_id: 123, bot_token: "backup-token"}],
        sender: fn token, message ->
          send(parent, {:attempt, token, message.edit_message_id})

          if is_integer(message.edit_message_id),
            do: {:error, %ExGram.Error{code: 401}},
            else: {:ok, %{message_id: 901}}
        end
      )

    :ok = Hub.configure(load_router!(), telegram)
    req = request()
    assert :ok = Hub.respond("ai-token", req.req_id, "text", "original")
    assert_receive {:attempt, original_bot, nil}
    assert {:error, :telegram_bot_unauthorized} = Hub.edit("ai-token", req.req_id, "text", "edit")
    assert_receive {:attempt, ^original_bot, 901}
    refute_receive {:attempt, _, _}
  end

  test "streaming text size is bounded without changing the one-shot API" do
    req = request()

    assert {:error, :invalid_payload} =
             Hub.respond("ai-token", req.req_id, "text", String.duplicate("😀", 65_537),
               final: false
             )

    assert Hub.status().delivery_health.pending == 1
    assert :ok = Hub.respond("ai-token", req.req_id, "file", "normal file")
  end

  defp request(opts \\ []) do
    assert {:ok, []} = Hub.poll("ai-token")

    :ok =
      Hub.incoming_service_message(
        Message.new(222, 123, "text", "/ai request", "bot-token", opts)
      )

    assert {:ok, [req]} = Hub.poll("ai-token")
    req
  end
end
