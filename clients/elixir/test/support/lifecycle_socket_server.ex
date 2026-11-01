defmodule ExironClient.LifecycleSocketServer do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 2]
  alias ExironClient.LifecycleGateway

  # An isolated loopback server for real SocketPoller/SocketTransport sessions.
  # Frame boundaries are decoded from the wire, including client masking.
  def start!(gateway) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!({Task, fn -> accept(listener, gateway) end},
      id: make_ref(),
      restart: :temporary
    )

    port
  end

  defp accept(listener, gateway) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          with {:ok, headers} <- headers(socket, "") do
            [key] =
              Regex.run(~r/sec-websocket-key:\s*([^\r]+)/i, headers, capture: :all_but_first)

            accept =
              :crypto.hash(:sha, String.trim(key) <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
              |> Base.encode64()

            :ok =
              :gen_tcp.send(socket, [
                "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
                accept,
                "\r\n\r\n"
              ])

            connected =
              ExironClient.FixtureHelpers.contract_json("websocket_connected_frame.json")

            :ok = send_json(socket, connected)

            if message = LifecycleGateway.message(gateway),
              do:
                send_json(socket, %{type: "messages", delivery_id: "batch", messages: [message]})

            frames(socket, gateway)
          end
        after
          :gen_tcp.close(socket)
        end

        accept(listener, gateway)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5000), do: headers(socket, buffer <> data)
    end
  end

  defp frames(socket, gateway) do
    with {:ok, <<_fin::1, _rsv::3, opcode::4, masked::1, length::7>>} <-
           :gen_tcp.recv(socket, 2, 5000),
         {:ok, length} <- length(socket, length),
         {:ok, mask} <- mask(socket, masked),
         {:ok, payload} <- payload(socket, length) do
      payload = unmask(payload, mask)

      case opcode do
        8 ->
          :ok

        9 ->
          send_frame(socket, 10, payload)
          frames(socket, gateway)

        1 ->
          case Jason.decode!(payload) do
            %{"type" => "ping"} ->
              send_json(socket, %{type: "pong"})
              frames(socket, gateway)

            %{"type" => "ack", "delivery_id" => "batch"} ->
              if LifecycleGateway.ack(gateway) == :ok, do: frames(socket, gateway), else: :ok
          end
      end
    end
  end

  defp length(socket, 126) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 5000), do: {:ok, length}
  end

  defp length(socket, 127) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, 5000), do: {:ok, length}
  end

  defp length(_, length), do: {:ok, length}
  defp mask(socket, 1), do: :gen_tcp.recv(socket, 4, 5000)
  defp mask(_, 0), do: {:ok, nil}
  defp payload(_, 0), do: {:ok, ""}
  defp payload(socket, length), do: :gen_tcp.recv(socket, length, 5000)
  defp unmask(payload, nil), do: payload

  defp unmask(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp send_json(socket, message), do: send_frame(socket, 1, Jason.encode!(message))

  defp send_frame(socket, opcode, payload) do
    length = byte_size(payload)

    header =
      if length < 126,
        do: <<1::1, 0::3, opcode::4, 0::1, length::7>>,
        else: <<1::1, 0::3, opcode::4, 0::1, 126::7, length::16>>

    :gen_tcp.send(socket, [header, payload])
  end
end
