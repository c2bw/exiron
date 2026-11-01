defmodule Exiron.Hub.CallbacksTest do
  use ExUnit.Case, async: false
  use Exiron.HubCase
  alias Exiron.Hub
  alias Exiron.Hub.{InlineKeyboard, Message, Telegram}
  alias Exiron.Hub.Telegram.Poller.UpdateProcessor
  alias Exiron.Hub.Telegram.PollerState

  setup do
    parent = self()
    router = load_push_router!()

    router = %{
      router
      | hooks: Map.put(router.hooks, "other", Exiron.Hub.HookToken.hash("other-token"))
    }

    telegram =
      Telegram.new([%{chat_id: 123, bot_token: "bot-token", bot_name: "helper"}],
        sender: fn _token, message ->
          send(parent, {:sent, message})
          {:ok, %{message_id: message.edit_message_id || 901}}
        end
      )

    :ok = Hub.configure(router, telegram)
    {:ok, []} = Hub.poll("ai-token")
    :ok
  end

  test "callback admission obeys the global payload budget and records rejection" do
    ref = menu()
    :sys.replace_state(Hub, &put_in(&1.settings.max_buffered_bytes, 1))
    pending = :sys.get_state(Hub).delivery.pending
    queues = :sys.get_state(Hub).delivery.queues
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(ref))
    assert :sys.get_state(Hub).delivery.pending == pending
    assert :sys.get_state(Hub).delivery.queues == queues
    assert Hub.status().buffer_capacity.request_rejections == 1
    assert Hub.status().delivery_health.overload_rejections == 1
  end

  test "buttons route only to their creator with clicker, source and topic metadata" do
    request = request()

    assert :ok =
             Hub.respond("ai-token", request.req_id, "text", "Choose",
               inline_keyboard: keyboard()
             )

    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: ref}]]}}
    assert {:ok, []} = Hub.poll("other-token", listen: :all)
    refute ref == "/other next"
    assert byte_size(ref) <= 64
    assert :ok = Hub.incoming_callback("bot-token", query(ref))
    assert {:ok, [click]} = Hub.poll("ai-token")
    assert click.datatype == "callback"
    assert Base.decode64!(click.data) == "/other next"
    assert click.from.id == 42
    assert click.message_id == 901
    assert click.message_thread_id == 7
    assert click.callback_query == %{id: "click-1", origin_req_id: request.req_id}
    assert {:ok, []} = Hub.poll("other-token", listen: :all)

    assert {:error, :request_not_assigned} =
             Hub.respond("other-token", click.req_id, "text", "stolen")

    assert :ok = Hub.respond("ai-token", click.req_id, "text", "new reply")
    assert_receive {:sent, %{edit_message_id: nil, data: "new reply"}}
  end

  test "each click is distinct but Telegram redelivery is deduplicated" do
    ref = menu()
    assert :ok = Hub.incoming_callback("bot-token", query(ref))
    assert :ok = Hub.incoming_callback("bot-token", query(ref))
    assert :ok = Hub.incoming_callback("bot-token", %{query(ref) | id: "click-2"})
    assert {:ok, [first, second]} = Hub.poll("ai-token")
    assert first.req_id != second.req_id
    assert Hub.status().delivery_health.pending == 2
  end

  test "forged data, wrong bot, chat, message and inline-mode queries are rejected" do
    ref = menu()

    for {token, query} <- [
          {"bot-token", query("/ai forged")},
          {"wrong-token", query(ref)},
          {"bot-token", put_in(query(ref), [:message, :chat, :id], 456)},
          {"bot-token", put_in(query(ref), [:message, :message_id], 902)},
          {"bot-token", Map.delete(query(ref), :message)}
        ] do
      assert {:error, :unavailable} = Hub.incoming_callback(token, query)
    end

    assert {:ok, []} = Hub.poll("ai-token")
  end

  test "clicked messages support streaming edits and explicit keyboard removal" do
    ref = menu()
    :ok = Hub.incoming_callback("bot-token", query(ref))
    {:ok, [click]} = Hub.poll("ai-token")

    assert {:ok, %{final: false}} =
             Hub.respond("ai-token", click.req_id, "text", "Working",
               edit_origin: true,
               final: false
             )

    assert_receive {:sent, %{edit_message_id: 901, inline_keyboard: [[%{callback_data: ^ref}]]}}
    assert :ok = Hub.respond("ai-token", click.req_id, "text", "Done", inline_keyboard: [])
    assert_receive {:sent, %{edit_message_id: 901, inline_keyboard: []}}
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", %{query(ref) | id: "late"})
  end

  test "editing text preserves buttons and keyboard-only edits replace them" do
    req = request()
    :ok = Hub.respond("ai-token", req.req_id, "text", "Choose", inline_keyboard: keyboard())
    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: old}]]}}
    assert :ok = Hub.edit("ai-token", req.req_id, "text", "Still choose")
    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: ^old}]]}}

    assert :ok =
             Hub.edit("ai-token", req.req_id, "keyboard", "", inline_keyboard: keyboard("new"))

    assert_receive {:sent, %{datatype: "keyboard", inline_keyboard: [[%{callback_data: new}]]}}
    refute old == new
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(old))
    assert :ok = Hub.incoming_callback("bot-token", query(new))
  end

  test "push media buttons can be edited through their callback without a reply receipt" do
    assert {:ok, 1} =
             Hub.push("ai-token", "file", "bytes", 123,
               inline_keyboard: keyboard(),
               message_thread_id: 8
             )

    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: ref}]]}}
    :ok = Hub.incoming_callback("bot-token", query(ref))
    {:ok, [click]} = Hub.poll("ai-token")
    assert click.callback_query.origin_req_id == nil
    assert click.message_thread_id == 8

    assert :ok =
             Hub.respond("ai-token", click.req_id, "keyboard", "",
               edit_origin: true,
               inline_keyboard: []
             )

    assert_receive {:sent, %{datatype: "keyboard", edit_message_id: 901, inline_keyboard: []}}
  end

  test "invalid keyboard or edit target leaves the request available" do
    req = request()

    for opts <- [
          [inline_keyboard: [[%{text: "Bad", callback_data: "x", url: "https://example.com"}]]],
          [inline_keyboard: [[%{text: "Bad", callback_data: String.duplicate("😀", 17)}]]],
          [inline_keyboard: [[%{text: "Bad", url: "javascript:alert(1)"}]]],
          [inline_keyboard: [%{text: "Bad"}]],
          [edit_origin: true]
        ] do
      assert {:error, :invalid_payload} =
               Hub.respond("ai-token", req.req_id, "text", "Choose", opts)
    end

    assert :ok = Hub.respond("ai-token", req.req_id, "text", "valid")
  end

  test "callbacks are acknowledged before a failing media download and not repeated on retry" do
    ref = menu()
    parent = self()

    state = %PollerState{
      token: "bot-token",
      offset: 10,
      max_download_bytes: 1024,
      answer_callback: fn _, id, result -> send(parent, {:answer, id, result}) end,
      get_file: fn _, _ ->
        send(parent, :download)
        {:error, %ExGram.Error{code: 500}}
      end
    }

    updates = [
      %{update_id: 10, message: %{chat: %{id: 123}, document: %{file_id: "slow"}}},
      %{update_id: 11, callback_query: query(ref)}
    ]

    state = UpdateProcessor.prioritize_callbacks(state, updates)
    assert_receive {:answer, "click-1", :ok}
    assert {:retry, 10, _} = UpdateProcessor.process(state, updates)
    assert_receive :download
    state = UpdateProcessor.prioritize_callbacks(state, updates)
    assert MapSet.member?(state.processed_callbacks, 11)
    refute_receive {:answer, _, _}
    assert {:ok, [_click]} = Hub.poll("ai-token")
  end

  test "offline hooks reject clicks without sending chat spam" do
    ref = menu()
    expire_client("assistant")
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(ref))
    refute_receive {:sent, _}
  end

  test "binding expiry and capacity are bounded" do
    state = :sys.get_state(Hub)

    message =
      Message.outgoing(222, 123, "text", "menu", "bot-token", inline_keyboard: keyboard())
      |> InlineKeyboard.prepare("request")

    message = %{message | message_id: 901}
    state = InlineKeyboard.remember(state, "assistant", message)
    [[%{callback_data: ref}]] = message.inline_keyboard
    assert {:ok, _} = InlineKeyboard.lookup(state, "bot-token", query(ref))
    state = update_in(state.delivery.callback_bindings[ref].at, &(&1 - 86_400_001))
    assert {:error, :unavailable} = InlineKeyboard.lookup(state, "bot-token", query(ref))

    state =
      Enum.reduce(1..51, state, fn id, state ->
        message =
          %{
            message
            | message_id: id,
              inline_keyboard:
                List.duplicate(List.duplicate(%{text: "x", callback_data: "x"}, 5), 20)
          }
          |> InlineKeyboard.prepare(nil)

        InlineKeyboard.remember(state, "assistant", message)
      end)

    assert map_size(state.delivery.callback_bindings) == 5000
    assert length(state.delivery.callback_order) == 5000
  end

  test "failed sends do not install replacement bindings" do
    ref = menu()

    :sys.replace_state(Hub, fn state ->
      telegram =
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, _ -> {:error, %ExGram.Error{code: 400, message: "failed"}} end
        )

      %{state | telegram: telegram}
    end)

    :ok = Hub.incoming_callback("bot-token", query(ref))
    {:ok, [click]} = Hub.poll("ai-token")

    assert {:error, _} =
             Hub.respond("ai-token", click.req_id, "keyboard", "",
               edit_origin: true,
               inline_keyboard: []
             )

    assert :ok = Hub.incoming_callback("bot-token", %{query(ref) | id: "another"})
    assert {:ok, [_]} = Hub.poll("ai-token")
  end

  test "bindings follow the actual fallback bot rather than the requested bot" do
    parent = self()

    telegram =
      Telegram.new(
        [%{chat_id: 123, bot_token: "bot-token"}, %{chat_id: 123, bot_token: "backup"}],
        sender: fn
          "bot-token", _ ->
            {:error, %ExGram.Error{code: 401}}

          "backup", message ->
            send(parent, {:sent, message})
            {:ok, %{message_id: 901}}
        end
      )

    :ok = Hub.configure(load_push_router!(), telegram)
    {:ok, []} = Hub.poll("ai-token")
    ref = menu()
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(ref))
    assert :ok = Hub.incoming_callback("backup", query(ref))
    assert {:ok, [_]} = Hub.poll("ai-token")
  end

  test "full queues reject clicks without consuming pending capacity or sending chat messages" do
    ref = menu()

    :sys.replace_state(Hub, fn state ->
      %{state | settings: %{state.settings | max_pending: 1}}
    end)

    assert :ok = Hub.incoming_callback("bot-token", query(ref))

    assert {:error, :unavailable} =
             Hub.incoming_callback("bot-token", %{query(ref) | id: "overflow"})

    assert {:ok, [_]} = Hub.poll("ai-token")
    refute_receive {:sent, _}
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

  defp menu do
    req = request()
    :ok = Hub.respond("ai-token", req.req_id, "text", "Choose", inline_keyboard: keyboard())
    assert_receive {:sent, %{inline_keyboard: [[%{callback_data: ref}]]}}
    ref
  end

  defp keyboard(data \\ "/other next"), do: [[%{text: "Next", callback_data: data}]]

  defp query(ref),
    do: %{
      id: "click-1",
      data: ref,
      from: %{id: 42, is_bot: false, first_name: "Ada"},
      message: %{message_id: 901, chat: %{id: 123}}
    }
end
