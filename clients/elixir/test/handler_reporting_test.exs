defmodule ExironClient.HandlerReportingTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Message, MessageHandler, PollerOptions, SocketWorker}

  for recovered? <- [false, true] do
    @tag recovered?: recovered?
    test "reports #{(recovered? && "recovery") || "exhaustion"} without changing retries when reporting fails",
         %{recovered?: recovered?} do
      parent = self()
      attempts = start_supervised!({Agent, fn -> 0 end})

      client =
        client(fn request ->
          send(parent, {:report, request.options.json})
          Req.Response.json(%Req.Response{status: 503}, %{error: "unavailable"})
        end)

      handler = fn _ ->
        attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        if recovered? and attempt == 3, do: :ok, else: {:error, "PRIVATE body and credentials"}
      end

      opts =
        PollerOptions.build!(
          client: client,
          handler: handler,
          report_handler_failures: true,
          handler_max_attempts: 3,
          on_handler_error: fn failure -> send(parent, {:failure, failure.reason}) end
        )

      handler_opts =
        opts.handler_options
        |> Keyword.put(:delivery_id, "batch")
        |> Keyword.put(:wait, fn _ -> :ok end)

      result =
        MessageHandler.handle(
          [%Message{req_id: "req-1", msgtype: "request"}],
          handler,
          handler_opts
        )

      assert result == if(recovered?, do: :ok, else: {:error, "PRIVATE body and credentials"})
      assert Agent.get(attempts, & &1) == 3

      for attempt <- 1..3 do
        assert_receive {:report, report}
        assert report.attempt == attempt
        assert report.delivery_id == "batch"
        assert report.client_id == "worker"
        refute inspect(report) =~ "PRIVATE"

        assert report.state ==
                 if(attempt == 3,
                   do: if(recovered?, do: "recovered", else: "exhausted"),
                   else: "retrying"
                 )
      end

      assert_receive {:failure, "PRIVATE body and credentials"}
    end
  end

  test "socket workers attach their batch and keep the original failure result" do
    parent = self()

    client =
      client(fn request ->
        send(parent, {:report, request.options.json})
        Req.Response.json(%{ok: true})
      end)

    handler = fn _ -> raise "PRIVATE exception" end
    opts = PollerOptions.build!(client: client, handler: handler, report_handler_failures: true)

    worker =
      start_supervised!(%{
        id: SocketWorker,
        start: {SocketWorker, :start_link, [parent, handler, opts.handler_options]}
      })

    assert {:ok, job} = SocketWorker.enqueue(worker, [%Message{req_id: "req-1"}], "socket-batch")

    assert_receive {:report,
                    %{state: "exhausted", category: "exception", delivery_id: "socket-batch"}}

    assert_receive {:handler_failed, ^worker, ^job, %RuntimeError{message: "PRIVATE exception"}}
    refute_receive {:handler_complete, _, _}
  end

  @tag capture_log: true
  test "managed HTTP poller reports a retry and recovery before acknowledging" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{poll: 0, handler: 0} end})

    client =
      client(fn request ->
        case request.url.path do
          "/api/handler-reports" ->
            send(parent, {:report, request.options.json})
            Req.Response.json(%{ok: true})

          "/api/requests" ->
            n = Agent.get_and_update(counts, fn s -> {s.poll + 1, %{s | poll: s.poll + 1}} end)

            if n == 1 do
              Req.Response.json(%{
                delivery_id: "http-batch",
                requests: [%{req_id: "req-1", msgtype: "request", datatype: "text", data: "eA=="}]
              })
            else
              send(parent, {:ack, URI.decode_query(request.url.query)["delivery_ack"], self()})

              receive do
                :stop -> Req.Response.json(%Req.Response{status: 409}, %{error: "stop"})
              end
            end
        end
      end)

    pid =
      start_supervised!(
        {ExironClient.Poller,
         client: client,
         transport: :http,
         report_handler_failures: true,
         handler_max_attempts: 2,
         handler_retry_delay_ms: 1,
         interval_ms: 1,
         handler: fn _ ->
           n =
             Agent.get_and_update(counts, fn s ->
               {s.handler + 1, %{s | handler: s.handler + 1}}
             end)

           if n == 1, do: {:error, :failed}, else: :ok
         end},
        restart: :temporary
      )

    assert_receive {:report, %{state: "retrying", delivery_id: "http-batch"}}, 1000
    assert_receive {:report, %{state: "recovered", delivery_id: "http-batch"}}, 1000
    assert_receive {:ack, "http-batch", ^pid}, 1000
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, %ExironClient.Error{message: "stop"}}, 1000
  end

  test "defaults add no traffic, listeners are excluded and unsupported servers reject opt-in" do
    parent = self()

    client =
      client(fn request ->
        send(parent, {:unexpected, request})
        Req.Response.json(%{ok: true})
      end)

    handler = fn _ -> {:error, :failure} end
    opts = PollerOptions.build!(client: client, handler: handler)

    assert {:error, :failure} =
             MessageHandler.handle([%Message{req_id: "req-1"}], handler, opts.handler_options)

    opts = PollerOptions.build!(client: client, handler: handler, report_handler_failures: true)

    assert {:error, :failure} =
             MessageHandler.handle(
               [%Message{req_id: "listen-1", msgtype: "listen"}],
               handler,
               Keyword.put(opts.handler_options, :delivery_id, "batch")
             )

    refute_receive {:unexpected, _}

    unsupported =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            {request, Req.Response.json(%{protocol_version: "1.15", capabilities: []})}
          end
        ]
      )

    assert_raise ArgumentError, ~r/does not support/, fn ->
      PollerOptions.build!(client: unsupported, handler: handler, report_handler_failures: true)
    end
  end

  defp client(response) do
    ExironClient.new(
      base_url: "http://exiron.test",
      token: "token",
      client_id: "worker",
      req_options: [
        adapter: fn request ->
          result =
            if request.url.path == "/api/capabilities",
              do:
                Req.Response.json(%{
                  protocol_version: "1.15",
                  capabilities: ["handler_failure_reporting"]
                }),
              else: response.(request)

          {request, result}
        end
      ]
    )
  end
end
