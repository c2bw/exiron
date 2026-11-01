defmodule ExironClient.SocketTransport do
  @moduledoc false

  use GenServer
  @behaviour ExironClient.SocketTransportBehaviour

  alias ExironClient.{Error, SocketCallback, SocketConnection, SocketFrameCodec}
  alias WebSockex.{Conn, Frame}

  defstruct [
    :url,
    :callback,
    :callback_state,
    :conn,
    :max_frame_size,
    :startup_error,
    options: [],
    codec: nil
  ]

  @doc false
  @impl ExironClient.SocketTransportBehaviour
  def start_link(url, callback, callback_state, options)
      when is_binary(url) and is_atom(callback) and is_list(options) do
    case GenServer.start_link(__MODULE__, {url, callback, callback_state, options}) do
      {:ok, pid} = started ->
        case GenServer.call(pid, :startup_result) do
          :ok ->
            started

          {:error, reason} ->
            Process.unlink(pid)
            GenServer.stop(pid, :normal)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @impl ExironClient.SocketTransportBehaviour
  def set_active(%Conn{} = conn, active), do: SocketConnection.set_active(conn, active)

  @doc false
  def frame_header(buffer), do: SocketFrameCodec.frame_header(buffer)

  @impl true
  def init({url, callback, callback_state, options}) do
    Process.flag(:trap_exit, true)

    callback_state =
      if callback == ExironClient.SocketPoller,
        do: ExironClient.RuntimeStatus.attach(callback_state),
        else: callback_state

    state = %__MODULE__{
      url: url,
      callback: callback,
      callback_state: callback_state,
      options: options,
      max_frame_size: Keyword.fetch!(options, :max_frame_size),
      codec: SocketFrameCodec.new(Keyword.fetch!(options, :max_frame_size))
    }

    case establish(state, 1) do
      {:ok, state} -> {:ok, state}
      {:stop, reason, state} -> {:ok, %{state | startup_error: reason}}
    end
  end

  @impl true
  def handle_call(:startup_result, _from, %{startup_error: nil} = state),
    do: {:reply, :ok, state}

  def handle_call(:startup_result, _from, state),
    do: {:reply, {:error, state.startup_error}, state}

  @impl true
  def handle_info(
        {transport, socket, data},
        %{conn: %Conn{transport: transport, socket: socket}} = state
      )
      when transport in [:tcp, :ssl] and is_binary(data) do
    state
    |> receive_data(data)
    |> handle_transport_result()
  end

  def handle_info({transport, _socket, _data}, state) when transport in [:tcp, :ssl],
    do: {:noreply, state}

  def handle_info(
        {closed, socket},
        %{conn: %Conn{socket: socket}} = state
      )
      when closed in [:tcp_closed, :ssl_closed] do
    handle_transport_result({:disconnect, {:remote, :closed}, state})
  end

  def handle_info({closed, _socket}, state) when closed in [:tcp_closed, :ssl_closed],
    do: {:noreply, state}

  def handle_info(
        {transport_error, socket, reason},
        %{conn: %Conn{socket: socket}} = state
      )
      when transport_error in [:tcp_error, :ssl_error] do
    handle_transport_result({:disconnect, {:error, reason}, state})
  end

  def handle_info({transport_error, _socket, _reason}, state)
      when transport_error in [:tcp_error, :ssl_error],
      do: {:noreply, state}

  def handle_info({:"$websockex_cast", message}, state) do
    state
    |> dispatch_callback(:handle_cast, message)
    |> process_after_callback()
    |> handle_transport_result()
  end

  def handle_info({:"$websockex_send", from, frame}, state) do
    result = send_frame(state, frame)
    :gen.reply(from, result)

    case result do
      :ok ->
        {:noreply, state}

      {:error, %WebSockex.ConnError{} = error} ->
        handle_transport_result({:disconnect, {:error, error}, state})

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    state
    |> dispatch_callback(:handle_info, message)
    |> process_after_callback()
    |> handle_transport_result()
  end

  @impl true
  def terminate(reason, state) do
    SocketConnection.close(state.conn)
    SocketCallback.terminate(state.callback, reason, state.callback_state)
    :ok
  end

  @impl true
  def format_status(status) do
    ExironClient.OTPStatus.redact(status, &status_state/1)
  end

  defp establish(state, attempt) do
    if state.callback == ExironClient.SocketPoller,
      do: ExironClient.RuntimeStatus.phase(state.callback_state, :connecting)

    case open_connection(state) do
      {:ok, conn} ->
        state = %{state | conn: conn, codec: SocketFrameCodec.new(state.max_frame_size)}

        case SocketCallback.invoke(state.callback, :handle_connect, [conn, state.callback_state]) do
          {:return, {:ok, callback_state}} ->
            state = %{state | callback_state: callback_state}

            case ensure_socket_active(state) do
              {:ok, state} -> {:ok, state}
              {:error, reason, state} -> disconnect_or_reconnect(reason, state, attempt)
            end

          {:exit, reason} ->
            {:stop, reason, state}

          {:return, response} ->
            {:stop,
             SocketCallback.bad_response(
               state.callback,
               :handle_connect,
               [conn, state.callback_state],
               response
             ), state}
        end

      {:error, reason, conn} ->
        disconnect_or_reconnect(reason, %{state | conn: conn}, attempt)
    end
  end

  defp open_connection(state) do
    SocketConnection.open(state.url, state.options, self())
  end

  defp receive_data(state, data) do
    with {:ok, codec} <- SocketFrameCodec.append(state.codec, data) do
      process_frames(%{state | codec: codec})
    else
      {:error, {:frame_too_large, frame_size}} -> frame_too_large(state, frame_size)
    end
  end

  defp process_frames(%{callback_state: %{socket_paused?: true}} = state),
    do: {:ok, state}

  defp process_frames(state) do
    case SocketFrameCodec.next_frame(state.codec) do
      {:ok, frame, codec} ->
        case handle_incoming_frame(frame, %{state | codec: codec}) do
          {:ok, state} -> process_frames(state)
          other -> other
        end

      :incomplete ->
        case ensure_socket_active(state) do
          {:ok, state} -> {:ok, state}
          {:error, reason, state} -> {:disconnect, {:error, reason}, state}
        end

      {:error, {:frame_too_large, frame_size}} ->
        frame_too_large(state, frame_size)

      {:error, {:protocol_error, reason}} ->
        protocol_error(state, reason)

      {:error, {:protocol_error, reason, _buffer}} ->
        protocol_error(state, reason)
    end
  end

  defp process_after_callback({:ok, state}), do: process_frames(state)
  defp process_after_callback(result), do: result

  defp frame_too_large(state, frame_size) do
    error =
      Error.new(
        :invalid_response,
        "websocket frame exceeds configured size limit of #{state.max_frame_size} bytes",
        body: %{frame_bytes: frame_size, max_response_bytes: state.max_frame_size}
      )

    callback_state =
      if is_map(state.callback_state) do
        Map.put(state.callback_state, :last_error, error)
      else
        state.callback_state
      end

    state = %{state | callback_state: callback_state}
    _ = send_frame(state, {:close, 1009, "message too big"})
    {:disconnect, {:local, 1009, "message too big"}, state}
  end

  defp handle_incoming_frame(:ping, state), do: dispatch_callback(state, :handle_ping, :ping)

  defp handle_incoming_frame({:ping, _payload} = frame, state),
    do: dispatch_callback(state, :handle_ping, frame)

  defp handle_incoming_frame(:pong, state), do: dispatch_callback(state, :handle_pong, :pong)

  defp handle_incoming_frame({:pong, _payload} = frame, state),
    do: dispatch_callback(state, :handle_pong, frame)

  defp handle_incoming_frame(:close, state) do
    _ = send_frame(state, :close)
    {:disconnect, {:remote, :normal}, state}
  end

  defp handle_incoming_frame({:close, code, reason}, state) do
    _ = send_frame(state, {:close, code, reason})
    {:disconnect, {:remote, code, reason}, state}
  end

  defp handle_incoming_frame(frame, state),
    do: dispatch_callback(state, :handle_frame, frame)

  defp protocol_error(state, message) do
    error = %WebSockex.FrameError{
      reason: :protocol_error,
      opcode: nil,
      buffer: state.codec.buffer
    }

    _ = send_frame(state, {:close, 1002, message})
    {:disconnect, {:error, error}, state}
  end

  defp dispatch_callback(state, function, message) do
    arguments = [message, state.callback_state]

    case SocketCallback.invoke(state.callback, function, arguments) do
      {:return, {:ok, callback_state}} ->
        {:ok, %{state | callback_state: callback_state}}

      {:return, {:reply, frame, callback_state}} ->
        state = %{state | callback_state: callback_state}

        case send_frame(state, frame) do
          :ok -> {:ok, state}
          {:error, reason} -> {:disconnect, {:error, reason}, state}
        end

      {:return, {:close, callback_state}} ->
        state = %{state | callback_state: callback_state}
        _ = send_frame(state, :close)
        {:disconnect, {:local, :normal}, state}

      {:return, {:close, {code, reason}, callback_state}} ->
        state = %{state | callback_state: callback_state}
        _ = send_frame(state, {:close, code, reason})
        {:disconnect, {:local, code, reason}, state}

      {:exit, reason} ->
        {:stop, reason, state}

      {:return, response} ->
        {:stop, SocketCallback.bad_response(state.callback, function, arguments, response), state}
    end
  end

  defp send_frame(%{conn: %Conn{socket: socket}} = state, frame) when not is_nil(socket) do
    with {:ok, encoded} <- Frame.encode_frame(frame) do
      Conn.socket_send(state.conn, encoded)
    end
  end

  defp send_frame(_state, _frame),
    do: {:error, %WebSockex.NotConnectedError{connection_state: :closed}}

  defp ensure_socket_active(%{callback_state: %{socket_paused?: true}} = state) do
    case set_socket_active(state.conn, false) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_socket_active(%{conn: %Conn{} = conn} = state) do
    case SocketConnection.active(conn) do
      {:ok, :once} -> {:ok, state}
      {:ok, true} -> {:ok, state}
      {:ok, false} -> set_socket_once(state)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_socket_active(state), do: {:error, :closed, state}

  defp set_socket_once(state) do
    case set_socket_active(state.conn, :once) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp set_socket_active(%Conn{} = conn, active),
    do: SocketConnection.set_active(conn, active)

  defp disconnect_or_reconnect(reason, state, attempt) do
    status_conn = state.conn
    SocketConnection.close(status_conn)
    state = %{state | conn: nil, codec: SocketFrameCodec.new(state.max_frame_size)}

    status = %{conn: status_conn, reason: reason, attempt_number: attempt}

    case SocketCallback.invoke(state.callback, :handle_disconnect, [
           status,
           state.callback_state
         ]) do
      {:return, {:reconnect, callback_state}} ->
        establish(%{state | callback_state: callback_state}, attempt + 1)

      {:return, {:reconnect, %Conn{}, callback_state}} ->
        establish(%{state | callback_state: callback_state}, attempt + 1)

      {:return, {:ok, callback_state}} ->
        {:stop, termination_reason(reason), %{state | callback_state: callback_state}}

      {:exit, callback_reason} ->
        {:stop, callback_reason, state}

      {:return, response} ->
        arguments = [status, state.callback_state]

        {:stop,
         SocketCallback.bad_response(state.callback, :handle_disconnect, arguments, response),
         state}
    end
  end

  defp handle_transport_result({:ok, state}), do: {:noreply, state}

  defp handle_transport_result({:disconnect, reason, state}) do
    case disconnect_or_reconnect(reason, state, 1) do
      {:ok, state} -> {:noreply, state}
      {:stop, stop_reason, state} -> {:stop, stop_reason, state}
    end
  end

  defp handle_transport_result({:stop, reason, state}), do: {:stop, reason, state}

  defp termination_reason({_, :normal}), do: :normal
  defp termination_reason({_, 1000, _reason}), do: :normal
  defp termination_reason({:error, reason}), do: reason
  defp termination_reason(reason), do: reason

  defp status_state(%__MODULE__{} = state) do
    callback_status =
      if function_exported?(state.callback, :format_status, 2) do
        state.callback.format_status(:normal, [[], state.callback_state])
      else
        :redacted
      end

    %{
      callback: state.callback,
      callback_status: callback_status,
      connected?: match?(%Conn{socket: socket} when not is_nil(socket), state.conn),
      buffered_bytes: byte_size(state.codec.buffer),
      fragmented_bytes: fragment_size(state.codec.fragment),
      max_frame_size: state.max_frame_size
    }
  end

  defp status_state(_state), do: :redacted

  defp fragment_size(%{size: size}), do: size
  defp fragment_size(_fragment), do: 0
end
