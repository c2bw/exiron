defmodule Exiron.ConversationRoutingTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Router, Telegram}

  setup do
    parent = self()
    counter = start_supervised!({Agent, fn -> 100 end})

    sender = fn _, message ->
      id = message.edit_message_id || Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:sent, message, id})
      {:ok, %{message_id: id}}
    end

    {:ok, router} =
      Router.load_definitions(%{
        "aliases" => %{"telegram" => %{"home" => 123}},
        "routes" => %{"home" => %{"middleware" => ["family"]}},
        "middlewares" => %{
          "family" => %{
            "routes" => %{
              "assistant" => %{"messages" => ["/ai"], "interaction" => %{"followups" => true}},
              "other" => %{"messages" => ["/other"]}
            }
          }
        },
        "hooks" => %{"assistant" => "ai-token", "other" => "other-token"}
      })

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    {:ok, []} = Hub.poll("other-token", client_id: "other")
    :ok = incoming("/ai hello", message_id: 1)
    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")
    assert :ok = Hub.respond("ai-token", request.req_id, "text", "answer")
    assert_receive {:sent, _, id}
    %{reply: id, request: request}
  end

  test "a reply routes to the same hook without requiring a command", %{
    reply: id,
    request: parent
  } do
    :ok = incoming("more please", reply_to_message_id: id)

    assert {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")
    assert request.data == "bW9yZSBwbGVhc2U="
    assert request.followup_req_id == parent.req_id
    refute request.req_id == parent.req_id
    refute Map.has_key?(parent, :followup_req_id)
    message = Message.incoming(222, 123, "text", "more", bot_token: "bot-token")

    refute Map.has_key?(
             Message.to_listen(%{message | followup_req_id: parent.req_id}),
             :followup_req_id
           )
  end

  test "streamed replies also establish follow-up context", %{reply: id} do
    :ok = incoming("stream please", reply_to_message_id: id)
    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")

    {:ok, %{final: false}} =
      Hub.respond("ai-token", request.req_id, "text", "partial", final: false)

    assert_receive {:sent, _, partial_id}
    :ok = Hub.respond("ai-token", request.req_id, "text", "complete")
    assert_receive {:sent, _, _}
    :ok = incoming("continue", reply_to_message_id: partial_id, message_id: 3)
    assert {:ok, [continued]} = Hub.poll("ai-token", client_id: "worker")
    assert continued.followup_req_id == request.req_id
  end

  test "explicit commands take precedence and unknown commands do not fall back", %{reply: id} do
    :ok = incoming("/other hello", reply_to_message_id: id)
    assert {:ok, [command]} = Hub.poll("other-token", client_id: "other")
    refute Map.has_key?(command, :followup_req_id)
    :ok = incoming("/unknown", reply_to_message_id: id, message_id: 3)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
  end

  test "wrong bot/chat/topic, stale history and disabled routes do not inherit", %{reply: id} do
    for opts <- [
          [bot_token: "other-token"],
          [chat_id: 456],
          [message_thread_id: 9],
          [reply_to_message_id: id + 50]
        ] do
      :ok = incoming("more", Keyword.merge([reply_to_message_id: id], opts))
    end

    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = Hub.configure(load_router!())
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = incoming("more", reply_to_message_id: id, message_id: 99)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
  end

  defp incoming(text, opts) do
    Hub.incoming_service_message(
      Message.incoming(
        Telegram.service_id(),
        Keyword.get(opts, :chat_id, 123),
        "text",
        text,
        Keyword.merge([bot_token: "bot-token", message_id: 2, from: %{id: 11}], opts)
      )
    )
  end
end
