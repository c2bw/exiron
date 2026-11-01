defmodule ExironClient.ConversationOrderingTest do
  use ExUnit.Case, async: true
  alias ExironClient.{ConversationOrder, Message, MessageHandler, PollerOptions}

  test "groups service chat and topic while preserving encounter order across bots" do
    messages = [
      %Message{req_id: "main-one", service_id: 222, chat_id: 123, instance: "a"},
      %Message{req_id: "topic-one", service_id: 222, chat_id: 123, message_thread_id: 10},
      %Message{req_id: "main-two", service_id: 222, chat_id: 123, instance: "b"},
      %Message{req_id: "topic-two", service_id: 222, chat_id: 123, message_thread_id: 10},
      %Message{req_id: "other-topic", service_id: 222, chat_id: 123, message_thread_id: 20},
      %Message{req_id: "other-chat", service_id: 222, chat_id: 456},
      %Message{req_id: "other-service", service_id: 333, chat_id: 123},
      %Message{req_id: "missing-chat", service_id: 222},
      %Message{req_id: "missing-service", chat_id: 123}
    ]

    actual =
      messages
      |> ConversationOrder.lanes()
      |> Enum.map(fn lane -> Enum.map(lane, & &1.req_id) end)

    assert actual == [
             ~w(main-one main-two),
             ~w(topic-one topic-two),
             ["other-topic"],
             ["other-chat"],
             ["other-service"],
             ~w(missing-chat missing-service)
           ]
  end

  test "busy chat does not block other conversations and retries finish before its next message" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{} end})

    messages =
      for id <- ~w(a1 a2 a3 b1 c1) do
        chat =
          case id do
            "b1" -> 2
            "c1" -> 3
            _ -> 1
          end

        %Message{req_id: id, service_id: 222, chat_id: chat}
      end

    handler = fn message ->
      attempt =
        Agent.get_and_update(counts, fn s ->
          n = Map.get(s, message.req_id, 0) + 1
          {n, Map.put(s, message.req_id, n)}
        end)

      send(parent, {:started, message.req_id, attempt, self()})

      receive do
        :finish -> :ok
      end

      if message.req_id == "a2" and attempt == 1, do: {:error, :retry}, else: :ok
    end

    task =
      start_supervised!(
        {Task,
         fn ->
           result =
             MessageHandler.handle(messages, handler,
               concurrency: 2,
               order_by_chat: true,
               max_attempts: 2,
               wait: fn _ -> :ok end
             )

           send(parent, {:result, result})
         end},
        restart: :temporary
      )

    ref = Process.monitor(task)

    initial =
      for _ <- 1..2 do
        assert_receive {:started, id, 1, pid}, 1000
        {id, pid}
      end
      |> Map.new()

    assert Map.keys(initial) |> Enum.sort() == ~w(a1 b1)
    send(initial["b1"], :finish)
    assert_receive {:started, "c1", 1, third}, 1000
    send(third, :finish)
    refute_receive {:started, _, _, _}
    send(initial["a1"], :finish)
    assert_receive {:started, "a2", 1, a2}, 1000
    send(a2, :finish)
    assert_receive {:started, "a2", 2, ^a2}, 1000
    refute_receive {:started, "a3", _, _}
    send(a2, :finish)
    assert_receive {:started, "a3", 1, a3}, 1000
    send(a3, :finish)
    assert_receive {:result, :ok}, 1000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
  end

  test "exhaustion stops following messages in every lane and queued conversations" do
    calls = start_supervised!({Agent, fn -> [] end})

    messages =
      for {id, chat} <- [{"a1", 1}, {"a2", 1}, {"b1", 2}, {"b2", 2}, {"c1", 3}],
          do: %Message{req_id: id, service_id: 222, chat_id: chat}

    assert {:error, :poison} =
             MessageHandler.handle(
               messages,
               fn message ->
                 Agent.update(calls, &[message.req_id | &1])
                 {:error, :poison}
               end,
               concurrency: 2,
               order_by_chat: true
             )

    ids = Agent.get(calls, & &1)
    assert length(ids) <= 2
    assert Enum.all?(ids, &(&1 in ~w(a1 b1)))
  end

  test "ordering is opt-in and rejects non-boolean configuration" do
    options =
      PollerOptions.build!(runtime_reporting: false, client: %{}, handler: fn _ -> :ok end)

    assert options.handler_options[:order_by_chat] == false

    for invalid <- [nil, "true", 1, :chat] do
      assert_raise ArgumentError, fn ->
        PollerOptions.build!(
          runtime_reporting: false,
          client: %{},
          handler: fn _ -> :ok end,
          handler_order_by_chat: invalid
        )
      end
    end
  end

  test "cancelled request releases its lane and does not cancel the next same-chat token" do
    parent = self()
    status = start_supervised!({Agent, fn -> "active" end})

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            response =
              if request.url.path == "/api/capabilities" do
                Req.Response.json(%{
                  protocol_version: "1.15",
                  capabilities: ["cooperative_cancellation"]
                })
              else
                id = URI.decode_query(request.url.query)["req_id"]
                state = if id == "first", do: Agent.get(status, & &1), else: "active"
                Req.Response.json(%{req_id: id, state: state, expires_in_ms: nil})
              end

            {request, response}
          end
        ]
      )

    opts =
      ExironClient.Cancellation.options!(
        [cooperative_cancellation: true, cancellation_interval_ms: 100],
        client
      )

    messages = for id <- ~w(first second), do: %Message{req_id: id, service_id: 222, chat_id: 1}

    task =
      start_supervised!(
        {Task,
         fn ->
           result =
             MessageHandler.handle(
               messages,
               fn message ->
                 token = ExironClient.Cancellation.current()

                 if message.req_id == "first" do
                   Agent.update(status, fn _ -> "cancelled" end)

                   receive do
                     {:exiron_request_cancelled, "first", :cancelled} -> :ok
                   after
                     2000 -> flunk("no cancellation")
                   end

                   {:error, :cancelled}
                 else
                   send(
                     parent,
                     {:next_token, token.req_id, ExironClient.Cancellation.cancelled?(token)}
                   )

                   :ok
                 end
               end,
               [concurrency: 2, order_by_chat: true] ++ opts
             )

           send(parent, {:result, result})
         end},
        restart: :temporary
      )

    ref = Process.monitor(task)
    assert_receive {:next_token, "second", false}, 2000
    assert_receive {:result, :ok}, 1000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
  end
end
