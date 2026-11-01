defmodule Exiron.Hub.SendMemoryTest do
  use ExUnit.Case, async: true
  import Exiron.Support.RouterHelper

  alias Exiron.Hub.{
    ClientOperations,
    DeliveryState,
    Message,
    PendingRequest,
    QueueBuffer,
    SendCommand,
    SendTasks,
    State,
    Telegram
  }

  alias Exiron.Secret

  test "small send tasks do not retain unrelated queued media" do
    router = load_router!("send-memory")
    message = Message.new(222, 123, "text", "small reply", "fake-token")

    state = %State{
      enabled?: true,
      router: router,
      telegram: Telegram.new([%{chat_id: 123, bot_token: "fake-token"}]),
      delivery: %DeliveryState{
        queues: %{
          "assistant" => QueueBuffer.from_items([%{data: :binary.copy(<<42>>, 1_048_576)}])
        },
        pending: %{"request" => PendingRequest.new(message, "assistant", make_ref())}
      }
    }

    from = {self(), make_ref()}

    transitions = [
      response:
        ClientOperations.respond(
          state,
          from,
          Secret.new("ai-token"),
          "request",
          "text",
          "reply",
          []
        ),
      push: ClientOperations.push(state, from, Secret.new("ai-token"), "text", "push", 123, []),
      background:
        SendTasks.start_background_sends(state, [
          SendCommand.background(:unavailable, "assistant", message)
        ])
    ]

    for {kind, transition} <- transitions do
      [%{kind: :start_send, payload: %{task: task}}] = transition.effects

      assert :erlang.external_size(task) < 65_536,
             "#{kind} send task retained unrelated Hub state"
    end
  end
end
