defmodule ExironClient.HandlerConcurrencyTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Message, MessageHandler, PollerOptions, SocketWorker}

  test "bounds active handlers and refills a slot while a sibling is blocked" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{active: 0, peak: 0} end})
    messages = for id <- ~w(one two three four), do: %Message{req_id: id}

    handler = fn message ->
      Agent.update(counts, fn s -> %{active: s.active + 1, peak: max(s.peak, s.active + 1)} end)
      send(parent, {:started, message.req_id, self()})

      receive do
        :finish -> :ok
      end

      Agent.update(counts, &%{&1 | active: &1.active - 1})
      :ok
    end

    task = run_batch(messages, handler, concurrency: 2)
    ref = Process.monitor(task)

    first =
      for _ <- 1..2 do
        assert_receive {:started, id, pid}, 1000
        {id, pid}
      end
      |> Map.new()

    assert Map.keys(first) |> Enum.sort() == ~w(one two)
    refute_receive {:started, _, _}
    send(first["one"], :finish)
    assert_receive {:started, "three", third}, 1000
    send(third, :finish)
    assert_receive {:started, "four", fourth}, 1000
    send(fourth, :finish)
    refute_receive {:result, _}
    send(first["two"], :finish)
    assert_receive {:result, :ok}, 1000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert Agent.get(counts, & &1) == %{active: 0, peak: 2}
  end

  test "exhausted retries wait for active siblings without changing callbacks" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{} end})

    handler = fn message ->
      Agent.update(counts, &Map.update(&1, message.req_id, 1, fn n -> n + 1 end))

      if message.req_id == "poison" do
        {:error, :poison}
      else
        send(parent, {:sibling, self()})

        receive do
          :finish -> :ok
        end
      end
    end

    # Both initial handlers must start before failure is released.
    release = start_supervised!({Agent, fn -> false end}, id: :release)

    handler = fn message ->
      if message.req_id == "poison" and not Agent.get(release, & &1) do
        send(parent, {:poison, self()})

        receive do
          :fail -> Agent.update(release, fn _ -> true end)
        end
      end

      handler.(message)
    end

    task =
      run_batch(
        [
          %Message{req_id: "poison", service_id: 222, chat_id: 1},
          %Message{req_id: "sibling", service_id: 222, chat_id: 2}
        ],
        handler,
        concurrency: 2,
        order_by_chat: true,
        max_attempts: 2,
        wait: fn _ -> :ok end,
        on_error: fn failure -> send(parent, {:failure, failure}) end
      )

    assert_receive {:poison, poison}, 1000
    assert_receive {:sibling, sibling}, 1000
    send(poison, :fail)
    assert_receive {:failure, %{attempt: 1, will_retry?: true}}
    assert_receive {:failure, %{attempt: 2, will_retry?: false}}
    refute_receive {:result, _}
    ref = Process.monitor(task)
    send(sibling, :finish)
    assert_receive {:result, {:error, :poison}}, 1000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert Agent.get(counts, & &1) == %{"poison" => 2, "sibling" => 1}
  end

  test "failure stops queued handlers and keeps fan-out bounded" do
    counts = start_supervised!({Agent, fn -> 0 end})
    messages = for id <- 1..20, do: %Message{req_id: to_string(id)}

    assert {:error, :poison} =
             MessageHandler.handle(
               messages,
               fn _ ->
                 Agent.update(counts, &(&1 + 1))
                 {:error, :poison}
               end,
               concurrency: 2
             )

    assert Agent.get(counts, & &1) <= 2
  end

  test "stopping a socket worker cleans up its active handler tasks" do
    parent = self()

    worker =
      start_supervised!(%{
        id: SocketWorker,
        restart: :temporary,
        start:
          {SocketWorker, :start_link,
           [
             parent,
             fn message ->
               send(parent, {:started, message.req_id, self()})

               receive do
                 :never -> :ok
               end
             end,
             [concurrency: 2, order_by_chat: true]
           ]}
      })

    assert {:ok, _} =
             SocketWorker.enqueue(
               worker,
               [
                 %Message{req_id: "one", service_id: 222, chat_id: 1},
                 %Message{req_id: "two", service_id: 222, chat_id: 2}
               ],
               "batch"
             )

    refs =
      for _ <- 1..2 do
        assert_receive {:started, _, pid}, 1000
        {Process.monitor(pid), pid}
      end

    ref = Process.monitor(worker)
    Process.exit(worker, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}

    for {monitor, pid} <- refs do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1000
    end

    refute_receive {:handler_complete, _, _}
  end

  test "default handler stays in its caller process and invalid limits are rejected" do
    owner = self()

    assert :ok =
             MessageHandler.handle([%Message{req_id: "one"}], fn _ ->
               assert self() == owner
               :ok
             end)

    opts = PollerOptions.build!(runtime_reporting: false, client: %{}, handler: fn _ -> :ok end)
    assert opts.handler_options[:concurrency] == 1

    for limit <- [0, -1, 65, "2"] do
      assert_raise ArgumentError, fn ->
        PollerOptions.build!(
          runtime_reporting: false,
          client: %{},
          handler: fn _ -> :ok end,
          handler_concurrency: limit
        )
      end
    end
  end

  @tag capture_log: true
  test "managed HTTP acknowledges only after every concurrent handler finishes" do
    parent = self()
    polls = start_supervised!({Agent, fn -> 0 end})

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            n = Agent.get_and_update(polls, &{&1 + 1, &1 + 1})

            response =
              if n == 1 do
                messages =
                  for id <- ~w(one two three),
                      do: %{
                        req_id: id,
                        service_id: 222,
                        chat_id: if(id == "one", do: 1, else: 2),
                        msgtype: "request",
                        datatype: "text",
                        data: "eA=="
                      }

                Req.Response.json(%{delivery_id: "batch", requests: messages})
              else
                send(parent, {:ack, URI.decode_query(request.url.query)["delivery_ack"], self()})

                receive do
                  :stop -> Req.Response.json(%Req.Response{status: 409}, %{error: "stop"})
                end
              end

            {request, response}
          end
        ]
      )

    pid =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false,
         client: client,
         transport: :http,
         handler_concurrency: 2,
         handler_order_by_chat: true,
         interval_ms: 1,
         handler: fn message ->
           send(parent, {:started, message.req_id, self()})

           receive do
             :finish -> :ok
           end
         end},
        restart: :temporary
      )

    initial =
      for _ <- 1..2 do
        assert_receive {:started, id, handler}, 1000
        {id, handler}
      end
      |> Map.new()

    assert Map.keys(initial) |> Enum.sort() == ~w(one two)
    send(initial["two"], :finish)
    assert_receive {:started, "three", third}, 1000
    send(third, :finish)
    refute_receive {:ack, _, _}
    ref = Process.monitor(pid)
    send(initial["one"], :finish)
    assert_receive {:ack, "batch", ^pid}, 1000
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, %ExironClient.Error{message: "stop"}}, 1000
  end

  test "socket worker completes only when every concurrent handler finishes" do
    parent = self()

    worker =
      start_supervised!(%{
        id: SocketWorker,
        start:
          {SocketWorker, :start_link,
           [
             parent,
             fn message ->
               send(parent, {:started, message.req_id, self()})

               receive do
                 :finish -> :ok
               end
             end,
             [concurrency: 2, order_by_chat: true]
           ]}
      })

    {:ok, job} =
      SocketWorker.enqueue(
        worker,
        for(
          id <- ~w(one two three),
          do: %Message{req_id: id, service_id: 222, chat_id: if(id == "one", do: 1, else: 2)}
        ),
        "batch"
      )

    initial =
      for _ <- 1..2 do
        assert_receive {:started, id, handler}, 1000
        {id, handler}
      end
      |> Map.new()

    send(initial["two"], :finish)
    assert_receive {:started, "three", third}, 1000
    send(third, :finish)
    refute_receive {:handler_complete, _, _}
    send(initial["one"], :finish)
    assert_receive {:handler_complete, ^worker, ^job}, 1000
  end

  test "cooperative cancellation is scoped to one concurrent handler" do
    parent = self()
    state = start_supervised!({Agent, fn -> "active" end})

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
                status = if id == "cancel", do: Agent.get(state, & &1), else: "active"
                Req.Response.json(%{req_id: id, state: status, expires_in_ms: nil})
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

    handler = fn message ->
      token = ExironClient.Cancellation.current()

      if message.req_id == "cancel" do
        Agent.update(state, fn _ -> "cancelled" end)

        receive do
          {:exiron_request_cancelled, "cancel", :cancelled} ->
            send(parent, {:cancelled, ExironClient.Cancellation.reason(token)})
        after
          2000 -> flunk("no cancellation")
        end

        {:error, :cancelled}
      else
        send(parent, {:sibling, self()})

        receive do
          :finish -> refute ExironClient.Cancellation.cancelled?(token)
        end

        :ok
      end
    end

    task =
      run_batch(
        [%Message{req_id: "cancel"}, %Message{req_id: "sibling"}],
        handler,
        [concurrency: 2] ++ opts
      )

    assert_receive {:sibling, sibling}, 1000
    assert_receive {:cancelled, :cancelled}, 2000
    refute_receive {:result, _}
    ref = Process.monitor(task)
    send(sibling, :finish)
    assert_receive {:result, :ok}, 1000
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
  end

  test "concurrent reports retain per-request attempt and batch identity" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{} end})

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        client_id: "worker",
        req_options: [
          adapter: fn request ->
            send(parent, {:report, request.options.json})
            {request, Req.Response.json(%{ok: true})}
          end
        ]
      )

    assert :ok =
             MessageHandler.handle(
               [
                 %Message{req_id: "one", service_id: 222, chat_id: 1},
                 %Message{req_id: "two", service_id: 222, chat_id: 2}
               ],
               fn message ->
                 n =
                   Agent.get_and_update(counts, fn s ->
                     n = Map.get(s, message.req_id, 0) + 1
                     {n, Map.put(s, message.req_id, n)}
                   end)

                 if n == 1, do: {:error, :private_failure}, else: :ok
               end,
               concurrency: 2,
               order_by_chat: true,
               max_attempts: 2,
               wait: fn _ -> :ok end,
               reporting_client: client,
               delivery_id: "batch"
             )

    reports =
      for _ <- 1..4 do
        assert_receive {:report, report}
        assert report.delivery_id == "batch"
        assert report.client_id == "worker"
        report
      end

    for {_id, reports} <- Enum.group_by(reports, & &1.req_id) do
      assert Enum.map(reports, & &1.state) == ["retrying", "recovered"]
      assert Enum.map(reports, & &1.attempt) == [1, 2]
    end
  end

  defp run_batch(messages, handler, opts) do
    parent = self()

    start_supervised!(
      {Task, fn -> send(parent, {:result, MessageHandler.handle(messages, handler, opts)}) end},
      restart: :temporary
    )
  end
end
