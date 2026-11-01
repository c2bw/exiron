defmodule ExironClient.RuntimeReportingTest do
  use ExUnit.Case, async: true
  alias ExironClient.{Poller, Error, HandlerDeadline, FixtureHelpers}

  for mode <- [:http, :graceful_http, :websocket] do
    @mode mode
    test "background reports continue during overdue #{@mode} work and die with their owner" do
      parent = self()
      calls = start_supervised!({Agent, fn -> [] end})

      {base_url, server} =
        if @mode == :websocket, do: websocket_server(), else: {"http://exiron.test", nil}

      client =
        ExironClient.new(
          base_url: base_url,
          token: "private-token",
          client_id: "worker",
          req_options: [
            adapter: fn req ->
              Agent.update(calls, &[req.url.path | &1])

              case req.url.path do
                "/api/capabilities" ->
                  {req,
                   Req.Response.json(%{
                     protocol_version: "1.17",
                     capabilities: [
                       "client_runtime_reporting",
                       "http_lease_renewal",
                       "client_retirement"
                     ]
                   })}

                "/api/requests" ->
                  {req,
                   Req.Response.json(%{
                     runtime_ref: "runtime-session",
                     delivery_id: "batch",
                     requests: [
                       %{
                         msgtype: "request",
                         req_id: "one",
                         datatype: "text",
                         data: Base.encode64("private-content")
                       }
                     ]
                   })}

                "/api/client-lease" ->
                  {req, Req.Response.json(%{ok: true, lease_timeout_ms: 3000})}

                "/api/client-runtime" ->
                  send(parent, {:report, req.options[:json], self()})
                  {req, %Req.Response{status: 503, body: %{"error" => "unavailable"}}}

                path ->
                  flunk("unexpected path #{path}")
              end
            end
          ]
        )

      ExUnit.CaptureLog.capture_log(fn ->
        opts = [
          client: client,
          transport: if(@mode == :websocket, do: :websocket, else: :http),
          handler_timeout_ms: 100,
          interval_ms: 10,
          graceful_shutdown: @mode == :graceful_http,
          http_lease_renewal: @mode != :websocket,
          handler: fn _ ->
            ref = HandlerDeadline.current().ref
            receive do: ({:exiron_handler_deadline, ^ref} -> :ok)
            send(parent, {:overdue, self()})
            receive do: (:release -> :ok)
          end
        ]

        pid =
          start_supervised!(%{
            id: make_ref(),
            restart: :temporary,
            start: {Poller, :start_link, [opts]}
          })

        owner_ref = Process.monitor(pid)
        assert_receive {:overdue, worker}, 1000
        assert_receive {:report, first, _request_pid}, 7000

        report =
          if first.overdue_handlers == 1 do
            first
          else
            assert_receive {:report, next, _request_pid}, 7000
            assert next.sequence > first.sequence
            next
          end

        assert report.overdue_handlers == 1
        assert report.active_handlers == 1
        assert report.phase == "handling"
        assert report.runtime_ref == "runtime-session"
        assert report.client_id == "worker"
        refute inspect(report) =~ "private-"
        {:dictionary, dictionary} = Process.info(pid, :dictionary)
        {_, table} = List.keyfind(dictionary, {ExironClient.RuntimeStatus, :table}, 0)
        [{:runtime_reporter, reporter}] = :ets.lookup(table, :runtime_reporter)
        reporter_ref = Process.monitor(reporter)
        refute_received {:DOWN, ^owner_ref, :process, ^pid, _}
        assert Enum.count(Agent.get(calls, & &1), &(&1 == "/api/capabilities")) == 1
        send(worker, :release)

        assert_receive {:DOWN, ^owner_ref, :process, ^pid,
                        %Error{reason: :handler_deadline_exceeded}},
                       1000

        assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, :normal}, 1500
      end)

      if server, do: send(server, :stop)
    end
  end

  test "reporting validates options and unsupported capability before consuming work" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        client_id: "worker",
        req_options: [
          adapter: fn req ->
            send(parent, {:request, req.url.path})
            {req, Req.Response.json(%{protocol_version: "1.16", capabilities: []})}
          end
        ]
      )

    assert_raise ArgumentError, "server does not support client_runtime_reporting", fn ->
      ExironClient.PollerOptions.build!(
        client: client,
        handler: fn _ -> :ok end,
        runtime_reporting: true
      )
    end

    assert_receive {:request, "/api/capabilities"}
    refute_received {:request, _}

    assert_raise ArgumentError, fn ->
      ExironClient.PollerOptions.build!(
        client: client,
        handler: fn _ -> :ok end,
        runtime_reporting: "yes"
      )
    end

    # Explicitly disabled mode performs no discovery and creates no reporter.
    state =
      ExironClient.PollerOptions.build!(
        client: client,
        handler: fn _ -> :ok end,
        runtime_reporting: false
      )

    state = ExironClient.RuntimeStatus.attach(state)
    refute state.handler_options[:runtime_reporting_client]
    refute_received {:request, _}
  end

  test "owner shutdown kills a blocked diagnostic request without waiting for its adapter" do
    parent = self()

    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        token: "token",
        client_id: "worker",
        req_options: [
          adapter: fn req ->
            case req.url.path do
              "/api/capabilities" ->
                {req,
                 Req.Response.json(%{
                   protocol_version: "1.17",
                   capabilities: ["client_runtime_reporting"]
                 })}

              "/api/requests" ->
                {req,
                 Req.Response.json(%{
                   runtime_ref: "session",
                   delivery_id: "batch",
                   requests: [
                     %{msgtype: "request", req_id: "one", datatype: "text", data: "eA=="}
                   ]
                 })}

              "/api/client-runtime" ->
                send(parent, {:blocked_report, self()})
                receive do: (:release -> {req, Req.Response.json(%{ok: true})})
            end
          end
        ]
      )

    id = make_ref()

    _pid =
      start_supervised!(%{
        id: id,
        restart: :temporary,
        start:
          {Poller, :start_link,
           [
             [
               client: client,
               transport: :http,
               runtime_reporting: true,
               handler: fn _ -> receive do: (:release -> :ok) end
             ]
           ]}
      })

    assert_receive {:blocked_report, rpc}, 1000
    ref = Process.monitor(rpc)
    stop_supervised!(id)
    assert_receive {:DOWN, ^ref, :process, ^rpc, :killed}, 1000
  end

  test "automatic reporting follows discovery and explicit opt-out skips discovery" do
    parent = self()

    for {mode, response, enabled?, discover?} <- [
          {:auto, %{protocol_version: "1.19", capabilities: ["client_runtime_reporting"]}, true,
           true},
          {:auto, %{protocol_version: "1.16", capabilities: []}, false, true},
          {:auto, %Req.Response{status: 503, body: %{"error" => "unavailable"}}, false, true},
          {false, %{protocol_version: "1.19", capabilities: ["client_runtime_reporting"]}, false,
           false}
        ] do
      client =
        ExironClient.new(
          base_url: "http://exiron.test",
          client_id: "worker",
          req_options: [
            adapter: fn req ->
              send(parent, {:discovery, req.url.path})

              response =
                if is_struct(response, Req.Response),
                  do: response,
                  else: Req.Response.json(response)

              {req, response}
            end
          ]
        )

      opts = [client: client, handler: fn _ -> :ok end]
      # Omission exercises the public default, not only an explicit :auto.
      opts = if mode == :auto, do: opts, else: Keyword.put(opts, :runtime_reporting, mode)
      state = ExironClient.PollerOptions.build!(opts)
      assert state.handler_options[:runtime_reporting_client] != nil == enabled?
      if discover?, do: assert_receive({:discovery, "/api/capabilities"})
      refute_received {:discovery, _}
    end
  end

  test "automatic reporting preserves clients whose IDs cannot support reports" do
    client =
      ExironClient.new(
        base_url: "http://exiron.test",
        client_id: String.duplicate("x", 129),
        req_options: [adapter: fn _ -> flunk("unexpected discovery") end]
      )

    state = ExironClient.PollerOptions.build!(client: client, handler: fn _ -> :ok end)
    refute state.handler_options[:runtime_reporting_client]

    assert_raise ArgumentError, fn ->
      ExironClient.PollerOptions.build!(
        client: client,
        handler: fn _ -> :ok end,
        runtime_reporting: true
      )
    end
  end

  defp websocket_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      start_supervised!(
        {Task,
         fn ->
           {:ok, socket} = :gen_tcp.accept(listener)
           request = headers(socket, "")
           [key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, request, capture: :all_but_first)

           challenge =
             :crypto.hash(:sha, String.trim(key) <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
             |> Base.encode64()

           :ok =
             :gen_tcp.send(socket, [
               "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
               challenge,
               "\r\n\r\n"
             ])

           connected =
             FixtureHelpers.contract_json("websocket_connected_frame.json")
             |> Map.put("runtime_ref", "runtime-session")
             |> Jason.encode!()

           :ok =
             :gen_tcp.send(socket, [
               frame(connected),
               frame(FixtureHelpers.websocket_messages_frame("one", "private-content"))
             ])

           receive do: (:stop -> :ok)
           :gen_tcp.close(socket)
           :gen_tcp.close(listener)
         end},
        id: make_ref(),
        restart: :temporary
      )

    on_exit(fn -> :gen_tcp.close(listener) end)
    {"http://127.0.0.1:#{port}", server}
  end

  defp headers(socket, data) do
    if String.contains?(data, "\r\n\r\n"),
      do: data,
      else:
        (case :gen_tcp.recv(socket, 0, 5000) do
           {:ok, next} -> headers(socket, data <> next)
         end)
  end

  defp frame(data) when byte_size(data) <= 125, do: <<0x81, byte_size(data), data::binary>>
  defp frame(data), do: <<0x81, 126, byte_size(data)::16, data::binary>>
end
