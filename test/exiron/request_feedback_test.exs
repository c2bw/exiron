defmodule Exiron.RequestFeedbackTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Telegram}

  @keyboard [
    [%{text: "Next", callback_data: "next"}],
    [
      %{text: "👍", callback_data: "exiron:feedback:v1:positive"},
      %{text: "👎", callback_data: "exiron:feedback:v1:negative"}
    ]
  ]

  setup do
    parent = self()
    counter = start_supervised!({Agent, fn -> 100 end})

    sender = fn _, message ->
      id = message.edit_message_id || Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:sent, message, id})
      {:ok, %{message_id: id}}
    end

    :ok =
      Hub.configure(
        load_router!(),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")

    :ok =
      Hub.incoming_service_message(
        Message.incoming(Telegram.service_id(), 123, "text", "/ai question",
          bot_token: "bot-token",
          message_id: 1,
          from: %{id: 42}
        )
      )

    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")
    %{request: request}
  end

  test "opt-in feedback preserves ordinary buttons and routes a bound rating with its origin", %{
    request: request
  } do
    :ok = Hub.respond("ai-token", request.req_id, "text", "Answer", inline_keyboard: @keyboard)
    assert_receive {:sent, answer, id}

    assert Enum.map(answer.inline_keyboard, &Enum.map(&1, fn b -> b.text end)) == [
             ["Next"],
             ["👍", "👎"]
           ]

    for {label, vote} <- [{"👍", "positive"}, {"👎", "negative"}] do
      button = answer.inline_keyboard |> List.flatten() |> Enum.find(&(&1.text == label))
      assert String.starts_with?(button.callback_data, "ex:")

      query = %{
        id: "rating-#{vote}",
        data: button.callback_data,
        from: %{id: 42},
        message: %{chat: %{id: 123}, message_id: id}
      }

      assert :ok = Hub.incoming_callback("bot-token", query)
      # The same Telegram callback retry is deduplicated.
      assert :ok = Hub.incoming_callback("bot-token", query)
      assert {:ok, [rating]} = Hub.poll("ai-token", client_id: "worker")
      assert rating.datatype == "callback"
      assert Base.decode64!(rating.data) == "exiron:feedback:v1:#{vote}"
      assert rating.callback_query.origin_req_id == request.req_id
      assert rating.from.id == 42
      assert rating.req_id != request.req_id
      assert :ok = Hub.respond("ai-token", rating.req_id, "text", "Thanks")
      assert_receive {:sent, _, _}
    end

    assert Hub.status().requested == 0
  end

  test "streaming remains optional and feedback can be attached only to the final update", %{
    request: request
  } do
    assert {:ok, %{final: false}} =
             Hub.respond("ai-token", request.req_id, "text", "Partial", final: false)

    assert_receive {:sent, partial, id}
    assert is_nil(partial.inline_keyboard)

    assert :ok =
             Hub.respond("ai-token", request.req_id, "text", "Complete",
               inline_keyboard: @keyboard
             )

    assert_receive {:sent, final, ^id}
    assert final.edit_message_id == id
    assert length(final.inline_keyboard) == 2
  end
end
