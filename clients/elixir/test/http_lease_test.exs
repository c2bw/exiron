defmodule ExironClient.HTTPLeaseTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Error, Lease}

  @tag capture_log: true
  test "long ordered HTTP batch renews through retries and final acknowledgement" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{renew: 0, poll: 0, first: 0} end})

    client =
      client(fn request ->
        case request.url.path do
          "/api/client-lease" ->
            n = bump(counts, :renew)
            send(parent, {:renewal, n})
            Req.Response.json(%{ok: true, lease_timeout_ms: 1200})

          "/api/handler-reports" ->
            send(parent, {:report, request.options.json.state})
            Req.Response.json(%{ok: true})

          "/api/requests" ->
            if bump(counts, :poll) == 1 do
              batch()
            else
              assert Lease.current() == nil
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
         http_lease_renewal: true,
         interval_ms: 1,
         handler_concurrency: 2,
         handler_order_by_chat: true,
         report_handler_failures: true,
         handler_max_attempts: 2,
         handler_retry_delay_ms: 1,
         handler: fn message ->
           token = Lease.current()
           assert token.delivery_id == "batch"
           refute Lease.lost?(token)

           if message.req_id == "first" and bump(counts, :first) == 1 do
             send(parent, {:started, self(), token})

             receive do
               :fail -> {:error, :temporary}
             end
           else
             :ok
           end
         end},
        restart: :temporary
      )

    assert_receive {:started, handler, token}, 1000

    for n <- 1..4 do
      assert_receive {:renewal, ^n}, 2000
    end

    refute_receive {:ack, _, _}
    send(handler, :fail)
    assert_receive {:report, "retrying"}, 1000
    assert_receive {:report, "recovered"}, 1000
    assert_receive {:ack, "batch", ^pid}, 1000
    assert Agent.get(counts, & &1.renew) >= 5
    assert :ets.info(token.handlers) == :undefined
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, %Error{message: "stop"}}, 1000
  end

  for mode <- [:lost, :unavailable, :timeout] do
    @tag capture_log: true, failure_mode: mode
    test "#{mode} renewal signals active tasks, stops queued work and withholds acknowledgement",
         %{failure_mode: mode} do
      parent = self()
      counts = start_supervised!({Agent, fn -> %{renew: 0, poll: 0} end})

      client =
        client(fn request ->
          case request.url.path do
            "/api/client-lease" ->
              if bump(counts, :renew) == 1 do
                Req.Response.json(%{ok: true, lease_timeout_ms: 600})
              else
                case mode do
                  :lost ->
                    Req.Response.json(%Req.Response{status: 409}, %{
                      code: "client_lease_lost",
                      error: "HTTP client lease could not be confirmed"
                    })

                  :unavailable ->
                    Req.Response.json(%Req.Response{status: 503}, %{error: "unavailable"})

                  :timeout ->
                    send(parent, {:blocked_control, self()})

                    receive do
                      :never -> Req.Response.json(%{ok: true, lease_timeout_ms: 600})
                    end
                end
              end

            "/api/requests" ->
              assert request.url.query |> URI.decode_query() |> Map.get("delivery_ack") == nil
              bump(counts, :poll)
              batch()
          end
        end)

      pid =
        start_supervised!(
          {ExironClient.Poller,
           client: client,
           transport: :http,
           http_lease_renewal: true,
           interval_ms: 1,
           handler_concurrency: 2,
           handler_order_by_chat: true,
           handler_max_attempts: 3,
           on_handler_error: fn failure -> send(parent, {:failure, failure}) end,
           handler: fn message ->
             if message.req_id == "queued", do: flunk("queued handler started after lease loss")
             token = Lease.current()

             receive do
               {:exiron_client_lease_lost, "batch"} ->
                 send(parent, {:lost, message.req_id, self(), Lease.lost?(token)})
             after
               2000 -> flunk("handler did not receive lease-loss signal")
             end

             if message.req_id == "other" do
               receive do
                 :finish -> :ok
               end
             end

             :ok
           end},
          restart: :temporary
        )

      ref = Process.monitor(pid)
      assert_receive {:lost, "first", _, true}, 2000
      assert_receive {:lost, "other", sibling, true}, 1000
      refute_receive {:DOWN, ^ref, _, _, _}
      send(sibling, :finish)

      assert_receive {:DOWN, ^ref, :process, ^pid, %Error{reason: :client_lease_lost} = error},
                     1000

      assert Error.client_lease_lost?(error)
      assert Agent.get(counts, & &1) == %{renew: 2, poll: 1}
      refute_receive {:failure, _}
    end
  end

  test "option is disabled by default and validates transport and capability before consuming" do
    assert [] == ExironClient.HTTPLease.options!([], %{})

    for options <- [[http_lease_renewal: "true"], [http_lease_renewal: true]] do
      assert_raise ArgumentError, fn -> ExironClient.HTTPLease.options!(options, %{}) end
    end

    unsupported =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        req_options: [
          adapter: fn request ->
            assert request.url.path == "/api/capabilities"
            {request, Req.Response.json(%{protocol_version: "1.15", capabilities: []})}
          end
        ]
      )

    assert_raise ArgumentError, ~r/does not support/, fn ->
      ExironClient.HTTPLease.options!([http_lease_renewal: true, transport: :http], unsupported)
    end
  end

  @tag capture_log: true
  test "owner shutdown cleans up a blocked renewal request" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{renew: 0} end})

    client =
      client(fn request ->
        if request.url.path == "/api/requests" do
          batch()
        else
          if bump(counts, :renew) == 1 do
            Req.Response.json(%{ok: true, lease_timeout_ms: 600})
          else
            send(parent, {:blocked, self()})

            receive do
              :never -> Req.Response.json(%{ok: true, lease_timeout_ms: 600})
            end
          end
        end
      end)

    pid =
      start_supervised!(
        {ExironClient.Poller,
         client: client,
         transport: :http,
         http_lease_renewal: true,
         interval_ms: 1,
         handler: fn _ ->
           receive do
             :never -> :ok
           end
         end},
        restart: :temporary
      )

    assert_receive {:blocked, request}, 1000
    request_ref = Process.monitor(request)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert_receive {:DOWN, ^request_ref, :process, ^request, _}, 1000
  end

  @tag capture_log: true
  test "failed initial renewal never starts handlers" do
    parent = self()

    client =
      client(fn request ->
        if request.url.path == "/api/requests",
          do: batch(),
          else:
            Req.Response.json(%Req.Response{status: 409}, %{
              code: "client_lease_lost",
              error: "HTTP client lease could not be confirmed"
            })
      end)

    pid =
      start_supervised!(
        {ExironClient.Poller,
         client: client,
         transport: :http,
         http_lease_renewal: true,
         interval_ms: 1,
         handler: fn _ -> send(parent, :unexpected_handler) end},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, %Error{reason: :client_lease_lost}}, 1000
    refute_receive :unexpected_handler
  end

  @tag capture_log: true
  test "failed final renewal marks the token lost and never acknowledges" do
    parent = self()
    counts = start_supervised!({Agent, fn -> %{renew: 0, poll: 0} end})

    client =
      client(fn request ->
        case request.url.path do
          "/api/requests" ->
            bump(counts, :poll)

            Req.Response.json(%{
              delivery_id: "batch",
              requests: [%{req_id: "one", datatype: "text", data: "eA=="}]
            })

          "/api/client-lease" ->
            if bump(counts, :renew) == 1,
              do: Req.Response.json(%{ok: true, lease_timeout_ms: 3000}),
              else:
                Req.Response.json(%Req.Response{status: 409}, %{
                  code: "client_lease_lost",
                  error: "HTTP client lease could not be confirmed"
                })
        end
      end)

    pid =
      start_supervised!(
        {ExironClient.Poller,
         client: client,
         transport: :http,
         http_lease_renewal: true,
         interval_ms: 1,
         handler: fn _ ->
           send(parent, {:token, Lease.current()})
           :ok
         end},
        restart: :temporary
      )

    ref = Process.monitor(pid)
    assert_receive {:token, token}, 1000
    assert_receive {:DOWN, ^ref, :process, ^pid, %Error{reason: :client_lease_lost}}, 1000
    assert Lease.lost?(token)
    assert Agent.get(counts, & &1) == %{renew: 2, poll: 1}
  end

  defp batch do
    messages =
      for {id, chat} <- [{"first", 1}, {"queued", 1}, {"other", 2}],
          do: %{
            req_id: id,
            msgtype: "request",
            service_id: 222,
            chat_id: chat,
            datatype: "text",
            data: "eA=="
          }

    Req.Response.json(%{delivery_id: "batch", requests: messages})
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
                  capabilities: ["http_lease_renewal", "handler_failure_reporting"]
                }),
              else: response.(request)

          {request, result}
        end
      ]
    )
  end

  defp bump(agent, field),
    do: Agent.get_and_update(agent, fn s -> {s[field] + 1, Map.put(s, field, s[field] + 1)} end)
end
