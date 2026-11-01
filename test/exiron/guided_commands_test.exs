defmodule Exiron.GuidedCommandsTest do
  use Exiron.HubCase, async: false
  alias Exiron.Hub
  alias Exiron.Hub.{Message, Router, Telegram, GuidedCommands}

  setup do
    parent = self()
    counter = start_supervised!({Agent, fn -> 100 end})

    sender = fn _, m ->
      id = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:sent, m, id, self()})
      {:ok, %{message_id: id}}
    end

    {:ok, router} =
      Router.load_definitions(%{
        "aliases" => %{"telegram" => %{"home" => 123}},
        "routes" => %{"home" => %{"middleware" => ["family"]}},
        "middlewares" => %{
          "family" => %{
            "routes" => %{
              "assistant" => %{"messages" => ["/ai"], "interaction" => %{"help" => true}}
            }
          }
        },
        "hooks" => %{"assistant" => "ai-token"}
      })

    :ok =
      Hub.configure(
        router,
        Telegram.new([%{chat_id: 123, bot_token: "bot-token"}], sender: sender)
      )

    {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    on_exit(fn -> Hub.resume_intake() end)
    :ok
  end

  test "Write asks for text without invoking a hook; its owner reply becomes one command request" do
    {prompt, id} = prompt()
    assert prompt.force_reply?
    assert prompt.reply_to_message_id == 1
    assert prompt.message_thread_id == 7
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    :ok = incoming("a question", reply_to_message_id: id)
    assert {:ok, [request]} = Hub.poll("ai-token", client_id: "worker", listen: true)
    assert Base.decode64!(request.data) == "/ai a question"
    assert request.from.id == 11 and request.message_thread_id == 7
    assert request.reply_to_message_id == id
    :ok = incoming("another question", reply_to_message_id: id, message_id: 3)
    _ = sent()
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
  end

  test "wrong owners/topics are blocked without listener copies; explicit commands keep precedence" do
    {_, id} = prompt()

    for opts <- [[from: %{id: 22}, message_id: 2], [message_thread_id: 8, message_id: 3]] do
      :ok = incoming("private input", Keyword.merge([reply_to_message_id: id], opts))
      _ = sent()
      assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    end

    :ok = incoming("/ai explicit", reply_to_message_id: id, message_id: 4)
    assert {:ok, [request]} = Hub.poll("ai-token", client_id: "worker", listen: true)
    assert Base.decode64!(request.data) == "/ai explicit"
    :ok = incoming("guided", reply_to_message_id: id, message_id: 5)
    assert {:ok, [request]} = Hub.poll("ai-token", client_id: "worker", listen: true)
    assert Base.decode64!(request.data) == "/ai guided"
  end

  test "expired prompts reject replies and new intake stays paused while draining" do
    {_, id} = prompt()

    :sys.replace_state(Hub, fn state ->
      update_in(state.delivery.command_prompts, fn prompts ->
        Map.new(prompts, fn {key, p} ->
          {key, %{p | expires: System.monotonic_time(:millisecond) - 1}}
        end)
      end)
    end)

    :ok = incoming("too late", reply_to_message_id: id)
    _ = sent()
    assert {:ok, []} = Hub.poll("ai-token", client_id: "worker", listen: true)
    {:ok, _} = Hub.start_drain()
    assert {:retry, :draining} = incoming("paused", reply_to_message_id: id, message_id: 3)
  end

  test "current access and help settings are checked again on input" do
    {_, id} = prompt()
    state = :sys.get_state(Hub)

    message =
      Message.incoming(222, 123, "text", "question",
        bot_token: "bot-token",
        reply_to_message_id: id,
        message_thread_id: 7,
        from: %{id: 11}
      )

    for policy <- [%{"help" => false}, %{"help" => true, "allowed_user_ids" => [22]}] do
      routes = Enum.map(state.router.routes, &Map.put(&1, :interaction, policy))

      router = %{
        state.router
        | routes: routes,
          routes_by_address: Enum.group_by(routes, &{&1.service_id, &1.chat_id})
      }

      assert :blocked = GuidedCommands.resolve(%{state | router: router}, message)
    end
  end

  test "prompt records are bounded and contain no entered question" do
    state = :sys.get_state(Hub)
    message = Message.outgoing(222, 123, "text", "prompt", "bot-token")

    state =
      Enum.reduce(1..501, state, fn id, state ->
        GuidedCommands.remember(state, %{
          message
          | message_id: id,
            command_prompt: %{command: "/ai", hook: "assistant", user_id: 11}
        })
      end)

    assert map_size(state.delivery.command_prompts) == 500
    assert length(state.delivery.command_prompt_order) == 500
  end

  defp prompt do
    :ok = incoming("/help", message_id: 1)
    {menu, menu_id} = sent()
    button = menu.inline_keyboard |> List.flatten() |> Enum.find(&(&1.text == "Write /ai"))

    query = %{
      id: "write-1",
      data: button.callback_data,
      from: %{id: 11},
      message: %{chat: %{id: 123}, message_id: menu_id}
    }

    assert {:ok, _} = Hub.incoming_callback("bot-token", query)
    assert {:ok, _} = Hub.incoming_callback("bot-token", query)
    {prompt, id} = sent()
    {prompt, id}
  end

  defp incoming(text, opts),
    do:
      Hub.incoming_service_message(
        Message.incoming(
          222,
          123,
          "text",
          text,
          Keyword.merge(
            [bot_token: "bot-token", message_id: 2, message_thread_id: 7, from: %{id: 11}],
            opts
          )
        )
      )

  defp sent do
    assert_receive {:sent, m, id, pid}, 1000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    _ = :sys.get_state(Hub)
    {m, id}
  end
end
