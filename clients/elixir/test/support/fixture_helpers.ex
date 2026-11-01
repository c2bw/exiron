defmodule ExironClient.FixtureHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 2]

  @contract_dir Path.expand("../../../../clients/contract", __DIR__)

  def adapter(requests) do
    fn request ->
      Agent.update(requests, &[request | &1])
      response = response_for(request)
      {request, response}
    end
  end

  def contract_json(name) do
    @contract_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  def response_for(%Req.Request{method: :post, url: %URI{path: "/api/auth"}}),
    do: Req.Response.json(contract_json("auth_response.json"))

  def response_for(%Req.Request{method: :get, url: %URI{path: "/api/requests"}}),
    do: Req.Response.json(contract_json("requests_response.json"))

  def response_for(%Req.Request{method: :post, url: %URI{path: "/api/responses"}}),
    do: Req.Response.json(contract_json("ok_response.json"))

  def response_for(%Req.Request{method: :post, url: %URI{path: "/api/push"}}),
    do: Req.Response.json(contract_json("push_response.json"))

  def response_for(%Req.Request{method: :get, url: %URI{path: "/api/status"}}),
    do: Req.Response.json(contract_json("status_response.json"))

  def response_for(%Req.Request{} = request) do
    raise "unexpected request path #{inspect(request.url.path)}"
  end

  def recorded_requests(requests) do
    requests
    |> Agent.get(& &1)
    |> Enum.reverse()
  end

  def has_authorization?(request, expected) do
    request.headers
    |> Map.get("authorization", [])
    |> Enum.any?(&(&1 == expected))
  end

  def fatal_handshake_server!(status, message) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         _request = :gen_tcp.recv(socket, 0, 5_000)
         body = ~s({"error":"invalid token"})

         response = [
           "HTTP/1.1 ",
           Integer.to_string(status),
           " ",
           message,
           "\r\ncontent-type: application/json\r\ncontent-length: ",
           Integer.to_string(byte_size(body)),
           "\r\nconnection: close\r\n\r\n",
           body
         ]

         :ok = :gen_tcp.send(socket, response)
         :gen_tcp.close(socket)
         :gen_tcp.close(listener)
       end},
      id: make_ref(),
      restart: :temporary
    )

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  def oversized_frame_server!(parent, payload_size) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         request = recv_headers(socket)
         [key] = Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, request, capture: :all_but_first)

         challenge =
           :crypto.hash(
             :sha,
             String.trim(key) <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
           )
           |> Base.encode64()

         response = [
           "HTTP/1.1 101 Switching Protocols\r\n",
           "upgrade: websocket\r\n",
           "connection: Upgrade\r\n",
           "sec-websocket-accept: ",
           challenge,
           "\r\n\r\n"
         ]

         :ok = :gen_tcp.send(socket, response)
         send(parent, {:websocket_handshake_complete, self()})

         receive do
           :send_oversized_header ->
             :ok = :gen_tcp.send(socket, oversized_text_header(payload_size))
         end

         send(parent, {:oversized_header_sent, payload_size})
         _result = :gen_tcp.recv(socket, 0, 5_000)
         :gen_tcp.close(socket)
         :gen_tcp.close(listener)
       end},
      id: make_ref(),
      restart: :temporary
    )

    on_exit(fn -> :gen_tcp.close(listener) end)

    port
  end

  def socket_state(parent, opts) do
    handler = Keyword.fetch!(opts, :handler)

    %ExironClient.SocketState{
      client: Keyword.get_lazy(opts, :client, &socket_client/0),
      handler: handler,
      interval_ms: 1,
      disconnect_timeout_ms: 10,
      on_connect: fn -> send(parent, :connected) end,
      on_protocol: fn protocol -> send(parent, {:protocol, protocol}) end,
      on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end,
      connected?: true,
      connection_state: :connected,
      conn: nil,
      last_seen_ms: System.monotonic_time(:millisecond),
      last_error: nil,
      reconnect_started_at_ms: nil,
      worker_pid: nil,
      worker_monitor_ref: nil,
      worker_job_ref: nil,
      worker_delivery_id: nil,
      socket_paused?: false,
      ping_ref: nil,
      ping_timer_ref: nil,
      protocol: %ExironClient.Protocol{}
    }
  end

  def websocket_messages_frame(req_id, data) do
    Jason.encode!(%{
      type: "messages",
      delivery_id: "delivery-#{req_id}",
      messages: [
        %{msgtype: "request", req_id: req_id, datatype: "text", data: Base.encode64(data)}
      ]
    })
  end

  def socket_client(opts \\ []) do
    reconnect_backoff =
      Keyword.get(opts, :reconnect_backoff,
        initial_delay_ms: 1,
        max_delay_ms: 8,
        max_retry_time_ms: 1_000,
        sleep: fn _delay_ms -> :ok end
      )

    ExironClient.new(
      base_url: "http://example.test",
      token: "ai-token",
      client_id: "poller",
      reconnect_backoff: reconnect_backoff
    )
  end

  defp recv_headers(socket, buffer \\ "") do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      recv_headers(socket, buffer <> data)
    end
  end

  defp oversized_text_header(payload_size) when payload_size <= 125,
    do: <<1::1, 0::3, 1::4, 0::1, payload_size::7>>

  defp oversized_text_header(payload_size) when payload_size <= 65_535,
    do: <<1::1, 0::3, 1::4, 0::1, 126::7, payload_size::16>>

  defp oversized_text_header(payload_size),
    do: <<1::1, 0::3, 1::4, 0::1, 127::7, payload_size::64>>
end
