defmodule Exiron.AccessPolicyTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{AccessPolicy, Configuration, Message, Router, Telegram}

  setup do
    parent = self()
    counter = start_supervised!({Agent, fn -> 100 end})

    sender = fn _, m ->
      id = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:sent, m, id, self()})
      {:ok, %{message_id: id}}
    end

    {:ok, router} = Router.load_definitions(definitions())

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: -123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    {:ok, []} = Hub.poll("other-token", client_id: "other", listen: true)
    :ok
  end

  test "denied routed messages never become requests or listener copies" do
    for {user, id} <- [{22, 1}, {nil, 2}] do
      :ok = incoming(user, id)
      {_notice, _} = sent()
    end

    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    assert {:ok, []} = Hub.poll("other-token", client_id: "other", listen: true)
    assert Hub.request_traces() == []
  end

  test "allowlisted users can invoke the hook and explicit admins can cancel their cards" do
    :ok = incoming(11, 1)
    {card, id} = sent()
    assert {:ok, [_]} = Hub.poll("ai-token", client_id: "worker")
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(card, id, 22))
    assert {:ok, text} = Hub.incoming_callback("bot-token", query(card, id, 33))
    assert text =~ "Request cancelled"
  end

  test "ordinary callbacks recheck access and cannot bypass restrictions" do
    :ok = incoming(11, 1)
    _ = sent()
    {:ok, [request]} = Hub.poll("ai-token", client_id: "worker")

    :ok =
      Hub.respond("ai-token", request.req_id, "text", "Choose",
        inline_keyboard: [[%{text: "Next", callback_data: "next"}]]
      )

    {reply, id} = sent()
    assert {:error, :unavailable} = Hub.incoming_callback("bot-token", query(reply, id, 22))
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
    assert :ok = Hub.incoming_callback("bot-token", query(reply, id, 11))
    assert {:ok, [%{datatype: "callback"}]} = Hub.poll("ai-token", client_id: "worker")
  end

  test "restrictions require schema 2 and survive full parsing and quick edits" do
    assert {:error, reason} = Router.load_definitions(Map.put(definitions(), "version", "1"))
    assert reason =~ "version 2"

    source =
      definitions()
      |> Map.put("telegram", %{
        "bots" => [%{"token" => "bot-token", "chats" => %{"home" => -123}}]
      })
      |> Exiron.Hub.RouteConfiguration.Encoder.encode()

    assert {:ok, config} = Configuration.read_source(source)
    assert config.version == "2"

    assert {:ok, edited} =
             Exiron.Hub.RouteConfiguration.Mutator.put_middleware_route(
               source,
               %{"middleware" => "family", "hook" => "assistant", "messages" => "/new"}
             )

    assert {:ok, config} = Configuration.read_source(edited)
    route = Enum.find(config.router.routes, &(&1.to == "assistant"))
    assert AccessPolicy.allowed?(route, %{id: 11})
    refute AccessPolicy.allowed?(route, %{id: 22})
    assert AccessPolicy.admin?(route, %{id: 33})
    assert {:ok, _} = Configuration.read_source("version: \"1\"\n")
  end

  test "restricted listeners and help do not expose unavailable commands" do
    message =
      Message.incoming(Telegram.service_id(), -123, "text", "hello",
        bot_token: "bot-token",
        message_id: 8,
        from: %{id: 22}
      )

    :ok = Hub.incoming_service_message(message)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)

    assert {:ok, [%{msgtype: "listen"}]} =
             Hub.poll("other-token", client_id: "other", listen: true)

    defs =
      put_in(
        definitions(),
        ["middlewares", "family", "routes", "assistant", "interaction", "help"],
        true
      )

    {:ok, router} = Router.load_definitions(defs)
    refute Exiron.Hub.CommandDiscovery.response(router, %{message | data: "/help"}, :error)

    assert Exiron.Hub.CommandDiscovery.response(
             router,
             %{message | data: "/help", from: %{id: 11}},
             :error
           )
  end

  test "empty allowlists deny everyone and malformed identifiers fail validation" do
    refute AccessPolicy.allowed?(%{interaction: %{"allowed_user_ids" => []}}, %{id: 11})

    for ids <- [["11"], [-1], [true], "all"] do
      assert_raise ArgumentError, fn ->
        Exiron.Hub.InteractionPolicy.parse!(%{"allowed_user_ids" => ids})
      end
    end

    defs =
      put_in(definitions(), ["middlewares", "family", "routes", "assistant2"], %{
        "messages" => ["/second"],
        "interaction" => %{"allowed_user_ids" => [22]}
      })
      |> put_in(["hooks", "assistant2"], "second-token")

    # Restrictions may differ across hooks, but conflicting routes to one hook fail closed.
    assert {:ok, _} = Router.load_definitions(defs)

    conflicting =
      definitions()
      |> put_in(["routes", "home", "middleware"], ["family", "conflict"])
      |> put_in(["middlewares", "conflict"], %{
        "routes" => %{"assistant" => %{"messages" => ["/second"]}}
      })

    assert {:error, reason} = Router.load_definitions(conflicting)
    assert reason =~ "access settings must agree"
  end

  defp definitions do
    %{
      "version" => "2",
      "aliases" => %{"telegram" => %{"home" => -123}},
      "routes" => %{"home" => %{"middleware" => ["family"]}},
      "middlewares" => %{
        "family" => %{
          "routes" => %{
            "assistant" => %{
              "messages" => ["/ai"],
              "interaction" => %{
                "request_controls" => true,
                "allowed_user_ids" => [11],
                "admin_user_ids" => [33]
              }
            },
            "other" => %{"messages" => ["/other"]}
          }
        }
      },
      "hooks" => %{"assistant" => "ai-token", "other" => "other-token"}
    }
  end

  defp incoming(user, id),
    do:
      Hub.incoming_service_message(
        Message.incoming(Telegram.service_id(), -123, "text", "/ai hello",
          bot_token: "bot-token",
          message_id: id,
          from: if(user, do: %{id: user})
        )
      )

  defp sent do
    assert_receive {:sent, m, id, pid}, 1000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Hub)
    {m, id}
  end

  defp query(card, id, user) do
    button = card.inline_keyboard |> List.flatten() |> List.last()

    %{
      id: "click-#{user}",
      data: button.callback_data,
      from: %{id: user},
      message: %{chat: %{id: -123}, message_id: id}
    }
  end
end
