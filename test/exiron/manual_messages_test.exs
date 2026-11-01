defmodule Exiron.ManualMessagesTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.Telegram

  setup do
    parent = self()

    :ok =
      Hub.configure(
        load_push_router!(),
        Telegram.new(
          [
            %{chat_id: 123, bot_token: "first-token", bot_name: "FirstBot"},
            %{chat_id: 123, bot_token: "second-token", bot_name: "SecondBot"}
          ],
          sender: fn token, message ->
            send(parent, {:sent, token, message})

            if token == "second-token",
              do: {:error, %ExGram.Error{code: 403, message: "Forbidden"}},
              else: {:ok, %{message_id: 91}}
          end
        )
      )

    [first, second] = Hub.manual_targets()
    %{first: first, second: second}
  end

  test "preview is inert and sends exactly the reviewed text, bot and topic once", %{first: first} do
    assert {:ok, draft} =
             Hub.preview_manual(%{
               "target" => first.id,
               "text" => " <b>hello</b> ",
               "topic" => "7"
             })

    refute_received {:sent, _, _}
    assert {:ok, 1} = Hub.send_manual(draft)
    assert_receive {:sent, "first-token", message}
    assert message.data == " <b>hello</b> "
    assert message.parse_mode == "plain"
    assert message.message_thread_id == 7
    assert {:ok, 1} = Hub.send_manual(draft)
    refute_received {:sent, _, _}
  end

  test "selected bot rejection does not fall back to another bot", %{second: second} do
    {:ok, draft} = Hub.preview_manual(%{"target" => second.id, "text" => "hello"})
    assert {:error, _} = Hub.send_manual(draft)
    assert_receive {:sent, "second-token", _}
    refute_received {:sent, "first-token", _}
  end

  test "unknown, blank, oversized and invalid-topic drafts fail before sending", %{first: first} do
    for params <- [
          %{"target" => "unknown", "text" => "hello"},
          %{"target" => first.id, "text" => " "},
          %{"target" => first.id, "text" => String.duplicate("x", 4097)},
          %{"target" => first.id, "text" => "hello", "topic" => "-1"}
        ] do
      assert {:error, :invalid_draft} = Hub.preview_manual(params)
    end

    refute_received {:sent, _, _}
  end

  test "media previews preserve bytes, caption, filename and topic without duplicate sends", %{
    first: first
  } do
    for {type, data, name} <- [
          {"image", <<137, "PNG", 13, 10, 26, 10, 1, 2, 3>>, "photo.png"},
          {"file", "file bytes", "report.txt"}
        ] do
      {:ok, draft} =
        Hub.preview_manual(%{
          "target" => first.id,
          "datatype" => type,
          "attachment" => %{data: data, file_name: name},
          "text" => "<b>caption</b>",
          "topic" => "9"
        })

      refute_received {:sent, _, _}
      assert {:ok, 1} = Hub.send_manual(draft)
      assert_receive {:sent, "first-token", message}
      assert message.datatype == type and message.data == data
      assert message.file_name == name and message.caption == "<b>caption</b>"
      assert message.message_thread_id == 9 and message.parse_mode == "plain"
      assert {:ok, 1} = Hub.send_manual(draft)
      refute_received {:sent, _, _}
      changed = %{draft | attachment: %{draft.attachment | data: data <> "changed"}}
      assert {:error, :idempotency_conflict} = Hub.send_manual(changed)
    end
  end

  test "invalid image contents, oversized files, unsafe names and long captions fail preview", %{
    first: first
  } do
    attachment = %{data: "bytes", file_name: "note.txt"}
    base = %{"target" => first.id, "datatype" => "file", "attachment" => attachment, "text" => ""}

    for params <- [
          Map.put(base, "datatype", "image"),
          Map.put(base, "attachment", %{attachment | data: String.duplicate("x", 10_000_001)}),
          Map.put(base, "attachment", %{attachment | file_name: "../note.txt"}),
          Map.put(base, "text", String.duplicate("x", 1025)),
          Map.put(base, "text", String.duplicate("😀", 513))
        ] do
      assert {:error, :invalid_draft} = Hub.preview_manual(params)
    end

    assert {:ok, _} = Hub.preview_manual(base)
    refute_received {:sent, _, _}
  end

  test "media shares the normal byte capacity admission", %{first: first} do
    {:ok, draft} =
      Hub.preview_manual(%{
        "target" => first.id,
        "datatype" => "file",
        "text" => "caption",
        "attachment" => %{data: "bytes", file_name: "note.txt"}
      })

    :sys.replace_state(Hub, fn state ->
      %{state | settings: %{state.settings | max_in_flight_send_bytes: 1}}
    end)

    assert {:error, :send_queue_full} = Hub.send_manual(draft)
    refute_received {:sent, _, _}
  end

  test "removed destinations and expired previews cannot send", %{first: first} do
    {:ok, draft} = Hub.preview_manual(%{"target" => first.id, "text" => "hello"})

    assert {:error, :stale_draft} =
             Hub.send_manual(%{draft | previewed_at: draft.previewed_at - :timer.minutes(11)})

    :ok = Hub.configure(load_router!())
    assert {:error, :stale_draft} = Hub.send_manual(draft)
    refute_received {:sent, _, _}
  end
end
