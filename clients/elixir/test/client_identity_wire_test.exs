defmodule ExironClient.ClientIdentityWireTest do
  use ExUnit.Case, async: true

  alias ExironClient.FixtureHelpers

  test "real HTTP polls carry one SDK identity alongside custom headers" do
    client =
      ExironClient.new(
        base_url: capture_server(:http),
        token: "test-token",
        client_id: "versioned-worker",
        req_options: [
          headers: [{"x-custom", "preserved"}, {"X-Exiron-SDK", "stale"}],
          pool_timeout: 1000,
          connect_options: [timeout: 1000]
        ]
      )

    assert {:ok, []} = ExironClient.requests(client)
    assert_receive {:wire_headers, headers}, 1_000
    assert_identity(headers)
    assert headers["authorization"] == ["Bearer test-token"]
    assert headers["x-custom"] == ["preserved"]
  end

  test "real HTTP requests retain a named Finch pool with bounded pool checkout" do
    start_supervised!({Finch, name: __MODULE__.Pool})

    client =
      ExironClient.new(
        base_url: capture_server(:http),
        token: "test-token",
        req_options: [finch: __MODULE__.Pool, pool_timeout: 1000]
      )

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert {:ok, []} = ExironClient.requests(client)
           end) == ""

    assert_receive {:wire_headers, headers}, 1000
    assert_identity(headers)
  end

  test "the default managed WebSocket transport puts SDK identity on the wire" do
    parent = self()

    client =
      ExironClient.new(
        base_url: capture_server(:websocket),
        token: "test-token",
        client_id: "versioned-worker"
      )

    pid =
      start_supervised!(
        {ExironClient.Poller,
         runtime_reporting: false,
         client: client,
         handler: fn _message -> :ok end,
         on_connect: fn -> send(parent, :connected) end,
         on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end}
      )

    assert_receive {:wire_headers, headers}, 1_000
    assert_identity(headers)
    assert headers["authorization"] == ["Bearer test-token"]
    assert_receive :connected, 1_000
    ref = Process.monitor(pid)
    assert :ok = stop_supervised(ExironClient.Poller)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert_receive {:disconnected, :shutdown}
    refute_receive {:disconnected, _reason}
  end

  defp assert_identity(headers) do
    assert headers["x-exiron-sdk"] == ["elixir"]
    assert headers["x-exiron-sdk-version"] == [ExironClient.Version.current()]
  end

  defp capture_server(transport) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)

         try do
           headers = receive_headers(socket, "")
           send(parent, {:wire_headers, headers})
           respond(socket, headers, transport)
         after
           :gen_tcp.close(socket)
         end
       end},
      id: make_ref(),
      restart: :temporary
    )

    "http://127.0.0.1:#{port}"
  end

  defp receive_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
      |> String.split("\r\n\r\n", parts: 2)
      |> hd()
      |> String.split("\r\n")
      |> tl()
      |> Enum.map(fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, buffer <> data)
    end
  end

  defp respond(socket, _headers, :http) do
    body = Jason.encode!(%{requests: []})

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
  end

  defp respond(socket, headers, :websocket) do
    [key] = headers["sec-websocket-key"]
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
        accept,
        "\r\n\r\n"
      ])

    connected = FixtureHelpers.contract_json("websocket_connected_frame.json") |> Jason.encode!()
    :ok = :gen_tcp.send(socket, <<0x81, 126, byte_size(connected)::16, connected::binary>>)
    receive do: (:stop -> :ok)
  end
end
