defmodule Exiron.RequestInteractionTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Router, Telegram}

  setup do
    parent = self()
    counter = start_supervised!({Agent, fn -> 900 end})

    sender = fn _, message ->
      id = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:telegram, message, id, self()})
      {:ok, %{message_id: id}}
    end

    :ok =
      Hub.configure(
        router(true),
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "owner can inspect queue/dispatch status and cancel accepted work during drain" do
    :ok = incoming()
    {card, id} = card()
    assert {:ok, "Waiting for worker."} = click(card, id, "Status", 11)
    assert {:ok, %{requests: [_]}} = Hub.poll_delivery("ai-token", client_id: "worker")
    assert {:ok, "Delivered to worker; waiting for its reply."} = click(card, id, "Status", 11)
    {:ok, _} = Hub.start_drain()
    assert {:ok, text} = click(card, id, "Cancel", 11)
    assert text =~ "Request cancelled"
    assert map_size(:sys.get_state(Hub).delivery.pending) == 0
    assert {:ok, "Request cancelled."} = click(card, id, "Status", 11)
    assert {:ok, text} = click(card, id, "Cancel", 11)
    assert text =~ "Request cancelled"
  end

  test "other users/chats/bots cannot operate an owner's card" do
    :ok = incoming()
    {card, id} = card()
    assert {:error, :unavailable} = click(card, id, "Cancel", 22)
    assert {:error, :unavailable} = click(card, id, "Status", 11, "other-token")
    query = query(card, id, "Cancel", 11) |> put_in([:message, :chat, :id], 456)
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query)
    assert map_size(:sys.get_state(Hub).delivery.pending) == 1
  end

  test "controls are opt-in and policy survives YAML encoding" do
    :ok = Hub.configure(router(false))
    {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    :ok = incoming()
    assert map_size(:sys.get_state(Hub).delivery.sends) == 0
    refute_received {:telegram, _, _, _}
    source = Exiron.Hub.RouteConfiguration.Encoder.encode(definitions(true))
    assert source =~ "request_controls: true"

    {:ok, edited} =
      Exiron.Hub.RouteConfiguration.Mutator.put_middleware_route(
        source,
        %{"middleware" => "family", "hook" => "assistant", "messages" => "/new"}
      )

    {:ok, parsed} = YamlElixir.read_from_string(edited)

    assert get_in(parsed, [
             "middlewares",
             "family",
             "routes",
             "assistant",
             "interaction",
             "request_controls"
           ]) == true

    assert_raise ArgumentError, fn ->
      Exiron.Hub.InteractionPolicy.parse!(%{"request_controls" => "yes"})
    end
  end

  defp definitions(enabled) do
    %{
      "version" => "1",
      "aliases" => %{"telegram" => %{"home" => 123}},
      "routes" => %{"home" => %{"middleware" => ["family"]}},
      "middlewares" => %{
        "family" => %{
          "routes" => %{
            "assistant" => %{
              "messages" => ["/ai"],
              "interaction" => %{"request_controls" => enabled}
            }
          }
        }
      },
      "hooks" => %{"assistant" => "ai-token"}
    }
  end

  defp router(enabled) do
    {:ok, router} = Router.load_definitions(definitions(enabled))
    router
  end

  defp incoming do
    Hub.incoming_service_message(
      Message.incoming(Telegram.service_id(), 123, "text", "/ai hello",
        bot_token: "bot-token",
        message_id: 1,
        from: %{id: 11}
      )
    )
  end

  defp card do
    assert_receive {:telegram, card, id, pid}, 1000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Hub)
    {card, id}
  end

  defp query(card, id, label, user) do
    button = card.inline_keyboard |> List.flatten() |> Enum.find(&(&1.text == label))

    %{
      id: "callback-#{label}-#{user}",
      data: button.callback_data,
      from: %{id: user},
      message: %{chat: %{id: 123}, message_id: id}
    }
  end

  defp click(card, id, label, user, token \\ "bot-token"),
    do: Hub.incoming_callback(token, query(card, id, label, user))
end
