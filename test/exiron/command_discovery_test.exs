defmodule Exiron.CommandDiscoveryTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Router, Telegram}

  setup do
    {:ok, router} =
      Router.load_definitions(%{
        "aliases" => %{"telegram" => %{"home" => 123, "work" => 456}},
        "routes" => %{
          "home" => %{"middleware" => ["home"]},
          "work" => %{"middleware" => ["work"]}
        },
        "middlewares" => %{
          "home" => %{
            "routes" => %{
              "assistant" => %{
                "messages" => ["/ai"],
                "interaction" => %{
                  "help" => true,
                  "description" => "Ask a question",
                  "example" => "/ai hello"
                }
              }
            }
          },
          "work" => %{"routes" => %{"assistant" => %{"messages" => ["/private"]}}}
        },
        "hooks" => %{"assistant" => "ai-token"}
      })

    parent = self()

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}],
          sender: fn _, m ->
            send(parent, {:help, m})
            send(parent, {:help_task, self()})
            {:ok, %{message_id: 99}}
          end
        )
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    on_exit(fn -> Hub.resume_intake() end)
    %{router: router}
  end

  test "help lists only commands opted in for this chat and stays out of listener queues" do
    :ok = Hub.incoming_service_message(message("/help"))
    assert_receive {:help, reply}, 1000
    assert reply.data =~ "/ai"
    assert reply.data =~ "Ask a question"
    assert reply.data =~ "Example: /ai hello"
    refute reply.data =~ "/private"
    assert reply.message_thread_id == 7
    assert reply.reply_to_message_id == 1
    assert reply.parse_mode == "plain"
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
  end

  test "addressed help only answers for this bot and existing routes keep precedence", %{
    router: router
  } do
    assert Exiron.Hub.CommandDiscovery.response(router, message("/help@MyBot"), :error)
    refute Exiron.Hub.CommandDiscovery.response(router, message("/help@OtherBot"), :error)

    refute Exiron.Hub.CommandDiscovery.response(
             router,
             %{message("/help") | chat_id: 456},
             :error
           )

    refute Exiron.Hub.CommandDiscovery.response(
             router,
             message("/help"),
             {:ok, hd(router.routes)}
           )
  end

  test "owner can select a command and callback retries create one routed request" do
    :ok = Hub.incoming_service_message(message("/help"))
    card = card()
    button = hd(hd(card.inline_keyboard))
    assert button.text == "Run /ai"
    assert String.starts_with?(button.callback_data, "ex:")
    query = query(button)
    assert {:ok, "Selected /ai."} = Hub.incoming_callback("bot-token", query)
    assert {:ok, "Selected /ai."} = Hub.incoming_callback("bot-token", query)
    assert {:ok, [request]} = Hub.poll("ai-token", client_id: "worker", listen: true)
    assert request.datatype == "text"
    assert Base.decode64!(request.data) == "/ai"
    assert request.from.id == 11
    assert request.message_thread_id == 7
    assert request.callback_query.id == "select-1"
    refute Map.has_key?(request, :followup_req_id)
  end

  test "menus are owner-bound, bot/chat-bound and paused during drain" do
    :ok = Hub.incoming_service_message(message("/help"))
    button = card().inline_keyboard |> hd() |> hd()
    query = query(button)

    assert {:error, :unavailable} =
             Hub.incoming_callback("bot-token", put_in(query, [:from, :id], 22))

    assert {:error, :unavailable} = Hub.incoming_callback("other-token", query)

    assert {:error, :unavailable} =
             Hub.incoming_callback("bot-token", put_in(query, [:message, :chat, :id], 456))

    {:ok, _} = Hub.start_drain()
    assert {:retry, :draining} = Hub.incoming_callback("bot-token", query)
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
  end

  test "selection rechecks current help settings and access lists", %{router: router} do
    :ok = Hub.incoming_service_message(message("/help"))
    card = card()
    button = card.inline_keyboard |> hd() |> hd()
    route = Enum.find(router.routes, &(&1.chat_id == 123))
    state = :sys.get_state(Hub)
    {:ok, binding} = Exiron.Hub.InlineKeyboard.lookup(state, "bot-token", query(button))

    for policy <- [%{"help" => false}, %{"help" => true, "allowed_user_ids" => [22]}] do
      routes =
        Enum.map(router.routes, fn r ->
          if r.id == route.id, do: Map.put(r, :interaction, policy), else: r
        end)

      router = %{
        router
        | routes: routes,
          routes_by_address: Enum.group_by(routes, &{&1.service_id, &1.chat_id})
      }

      assert %{reply: {:error, :unavailable}} =
               Exiron.Hub.CommandDiscovery.select(
                 %{state | router: router},
                 binding,
                 "bot-token",
                 query(button)
               )
    end

    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker")
  end

  test "menus stay bounded and unknown users receive text help without buttons", %{router: router} do
    route = Enum.find(router.routes, &(&1.chat_id == 123))
    routes = [%{route | messages: Enum.map(1..40, &"/command#{&1}")}]

    card =
      Exiron.Hub.CommandDiscovery.response(%{router | routes: routes}, message("/help"), :error)

    assert length(List.flatten(card.inline_keyboard)) == 40
    assert Exiron.Hub.InlineKeyboard.valid?("text", card.inline_keyboard)
    plain = Exiron.Hub.CommandDiscovery.response(router, %{message("/help") | from: nil}, :error)
    assert is_nil(plain.inline_keyboard)
  end

  defp card do
    assert_receive {:help, card}, 1000
    assert_receive {:help_task, pid}, 1000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Hub)
    card
  end

  defp query(button),
    do: %{
      id: "select-1",
      data: button.callback_data,
      from: %{id: 11},
      message: %{chat: %{id: 123}, message_id: 99}
    }

  test "help metadata survives canonical YAML with quoted special characters" do
    policy = %{"help" => true, "description" => "Ask: yes # safely", "example" => "/ai \"hello\""}
    yaml = "route:\n" <> Exiron.Hub.InteractionPolicy.encode(policy)
    {:ok, parsed} = YamlElixir.read_from_string(yaml)
    assert parsed["route"]["interaction"] == policy
    assert_raise ArgumentError, fn -> Exiron.Hub.InteractionPolicy.parse!(%{"help" => 1}) end
  end

  defp message(text),
    do:
      Message.incoming(Telegram.service_id(), 123, "text", text,
        bot_token: "bot-token",
        bot_name: "MyBot",
        message_id: 1,
        message_thread_id: 7,
        from: %{id: 11}
      )
end
