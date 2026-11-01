defmodule ExironClient.CooperativeCancellationTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Cancellation, Message, MessageHandler, PollerOptions, SocketWorker}

  for reason <- [:cancelled, :expired] do
    @reason reason
    test "socket worker cooperates with #{@reason} and completes siblings" do
      reason = @reason
      parent = self()
      status = start_supervised!({Agent, fn -> "active" end})

      client =
        client(fn request ->
          state = Agent.get(status, & &1)
          id = URI.decode_query(request.url.query)["req_id"]
          Req.Response.json(%{req_id: id, state: state, expires_in_ms: nil})
        end)

      handler = fn message ->
        if message.req_id == "one" do
          token = Cancellation.current()
          Agent.update(status, fn _ -> Atom.to_string(reason) end)

          receive do
            {:exiron_request_cancelled, "one", ^reason} ->
              send(
                parent,
                {:cancelled, Cancellation.cancelled?(token), Cancellation.reason(token)}
              )
          after
            2000 -> flunk("handler did not receive cancellation")
          end

          Agent.update(status, fn _ -> "active" end)
          {:error, :should_not_retry}
        else
          send(parent, {:sibling, message.req_id})
          :ok
        end
      end

      opts =
        PollerOptions.build!(
          client: client,
          handler: handler,
          cooperative_cancellation: true,
          cancellation_interval_ms: 100,
          handler_max_attempts: 3,
          on_handler_error: fn failure -> send(parent, {:failure, failure}) end,
          on_request_cancelled: fn event -> send(parent, {:notice, event}) end
        )

      worker =
        start_supervised!(%{
          id: SocketWorker,
          start: {SocketWorker, :start_link, [parent, handler, opts.handler_options]}
        })

      assert {:ok, job} =
               SocketWorker.enqueue(worker, [%Message{req_id: "one"}, %Message{req_id: "two"}])

      assert_receive {:cancelled, true, ^reason}, 2000
      assert_receive {:notice, %{request_id: "one", reason: ^reason}}
      assert_receive {:sibling, "two"}
      assert_receive {:handler_complete, ^worker, ^job}
      refute_receive {:failure, _}
    end
  end

  test "pre-cancelled work is skipped, listeners remain unchanged and token is cleared" do
    client =
      client(fn request ->
        id = URI.decode_query(request.url.query)["req_id"]
        Req.Response.json(%{req_id: id, state: "cancelled", expires_in_ms: nil})
      end)

    opts = Cancellation.options!([cooperative_cancellation: true], client)
    parent = self()

    assert :ok =
             MessageHandler.handle(
               [
                 %Message{req_id: "one"},
                 %Message{req_id: "two", msgtype: "listen"}
               ],
               fn message -> send(parent, {:handled, message.req_id}) end,
               opts
             )

    assert_receive {:handled, "two"}
    refute_receive {:handled, "one"}
    refute_receive {:exiron_request_cancelled, _, _}
    assert Cancellation.current() == nil
  end

  test "failed state checks do not cancel handlers and watcher is stopped on return" do
    parent = self()
    queries = start_supervised!({Agent, fn -> 0 end})

    client =
      client(fn _request ->
        n = Agent.get_and_update(queries, &{&1 + 1, &1 + 1})

        if n == 2 do
          send(parent, {:watcher, self()})

          receive do
            :never_sent -> :ok
          end
        end

        Req.Response.json(%Req.Response{status: 503}, %{error: "unavailable"})
      end)

    opts =
      Cancellation.options!(
        [cooperative_cancellation: true, cancellation_interval_ms: 100],
        client
      )

    assert :ok =
             MessageHandler.handle(
               [%Message{req_id: "one"}],
               fn _ ->
                 assert_receive {:watcher, watcher}, 2000
                 ref = Process.monitor(watcher)
                 send(parent, {:watcher_monitor, ref, watcher})
                 refute Cancellation.cancelled?()
                 :ok
               end,
               opts
             )

    assert_receive {:watcher_monitor, ref, watcher}
    assert_receive {:DOWN, ^ref, :process, ^watcher, :killed}, 2000
  end

  test "unsupported servers are rejected only when enabled" do
    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            {request, Req.Response.json(%{protocol_version: "1.15", capabilities: []})}
          end
        ]
      )

    assert [] == Cancellation.options!([], client)

    assert_raise ArgumentError, ~r/does not support/, fn ->
      Cancellation.options!([cooperative_cancellation: true], client)
    end
  end

  @tag capture_log: true
  test "managed HTTP poller acknowledges a cancelled batch and keeps its sibling" do
    parent = self()
    state = start_supervised!({Agent, fn -> %{polls: 0, status: "active"} end})

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            response =
              case request.url.path do
                "/api/capabilities" ->
                  Req.Response.json(%{
                    protocol_version: "1.15",
                    capabilities: ["cooperative_cancellation"]
                  })

                "/api/request-state" ->
                  id = URI.decode_query(request.url.query)["req_id"]

                  Req.Response.json(%{
                    req_id: id,
                    state: Agent.get(state, & &1.status),
                    expires_in_ms: nil
                  })

                "/api/requests" ->
                  n =
                    Agent.get_and_update(state, fn s ->
                      {s.polls + 1, %{s | polls: s.polls + 1}}
                    end)

                  if n == 1 do
                    Req.Response.json(%{
                      delivery_id: "batch",
                      requests: [
                        %{msgtype: "request", req_id: "one", datatype: "text", data: "eA=="},
                        %{msgtype: "request", req_id: "two", datatype: "text", data: "eQ=="}
                      ]
                    })
                  else
                    send(
                      parent,
                      {:ack, URI.decode_query(request.url.query)["delivery_ack"], self()}
                    )

                    receive do
                      :stop_poll ->
                        Req.Response.json(%Req.Response{status: 409}, %{error: "stop"})
                    end
                  end
              end

            {request, response}
          end
        ]
      )

    pid =
      start_supervised!(
        {ExironClient.Poller,
         client: client,
         transport: :http,
         cooperative_cancellation: true,
         cancellation_interval_ms: 100,
         interval_ms: 1,
         handler: fn message ->
           if message.req_id == "one" do
             Agent.update(state, &%{&1 | status: "cancelled"})

             receive do
               {:exiron_request_cancelled, "one", :cancelled} -> :ok
             after
               2000 -> flunk("missing cancellation")
             end

             Agent.update(state, &%{&1 | status: "active"})
             {:error, :cancelled_work}
           else
             send(parent, :sibling_handled)
           end
         end},
        restart: :temporary
      )

    assert_receive :sibling_handled, 2000
    assert_receive {:ack, "batch", ^pid}, 2000
    ref = Process.monitor(pid)
    send(pid, :stop_poll)
    assert_receive {:DOWN, ^ref, :process, ^pid, %ExironClient.Error{message: "stop"}}, 2000
  end

  defp client(state_response) do
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
              state_response.(request)
            end

          {request, response}
        end
      ]
    )
  end
end
