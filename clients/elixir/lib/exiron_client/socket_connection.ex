defmodule ExironClient.SocketConnection do
  @moduledoc false

  alias WebSockex.Conn

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def open(url, options, owner) do
    case Conn.new(url, options) do
      %Conn{} = conn -> open_socket(conn, owner)
      {:error, reason} -> {:error, reason, nil}
    end
  end

  def active(%Conn{conn_mod: :gen_tcp, socket: socket}) do
    case :inet.getopts(socket, [:active]) do
      {:ok, [active: active]} -> {:ok, active}
      {:error, reason} -> {:error, reason}
    end
  end

  def active(%Conn{conn_mod: :ssl, socket: socket}) do
    case :ssl.getopts(socket, [:active]) do
      {:ok, [active: active]} -> {:ok, active}
      {:error, reason} -> {:error, reason}
    end
  end

  def set_active(%Conn{} = conn, active), do: Conn.set_active(conn, active)

  def close(%Conn{} = conn) do
    _conn = Conn.close_socket(conn)
    :ok
  catch
    _, _reason -> :ok
  end

  def close(_conn), do: :ok

  defp open_socket(conn, owner) do
    case Conn.open_socket(conn) do
      {:ok, conn} -> perform_handshake(conn, owner)
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp perform_handshake(conn, owner) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    with {:ok, request} <- Conn.build_request(conn, key),
         :ok <- Conn.socket_send(conn, request),
         {:ok, headers} <- Conn.handle_response(conn, owner),
         :ok <- validate_handshake(headers, key) do
      {:ok, %{conn | resp_headers: headers}}
    else
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp validate_handshake(headers, key) do
    challenge = :crypto.hash(:sha, key <> @handshake_guid) |> Base.encode64()

    response =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(to_string(name)) == "sec-websocket-accept", do: value
      end)

    if response == challenge do
      :ok
    else
      {:error, %WebSockex.HandshakeError{response: response, challenge: challenge}}
    end
  end
end
