defmodule ExironClient.SocketPoller do
  @moduledoc false

  use WebSockex

  alias ExironClient.{
    ClientDrain,
    DeliveryWorker,
    Error,
    ReconnectPolicy,
    Message,
    Protocol,
    SocketBackoff,
    SocketDelivery,
    SocketError,
    SocketLifecycle,
    SocketState,
    SocketTransport,
    SocketUrl,
    Validation
  }

  @disconnect_notified_key {__MODULE__, :disconnect_notified}

  @messages_frame Protocol.server_frame_type(:messages)
  @connected_frame Protocol.server_frame_type(:connected)
  @pong_frame Protocol.server_frame_type(:pong)
  @error_frame Protocol.server_frame_type(:error)
  @ping_frame Protocol.client_frame_type(:ping)
  @ack_frame Protocol.client_frame_type(:ack)

  def start_link(opts) when is_list(opts) do
    state = state!(opts)

    apply(state.socket_transport, :start_link, [
      SocketUrl.build(state.client),
      __MODULE__,
      state,
      websockex_options(state.client)
    ])
  end

  @doc false
  def websockex_options(client) do
    [
      extra_headers: [
        Validation.bearer_header(client.token),
        {"x-exiron-sdk", "elixir"},
        {"x-exiron-sdk-version", ExironClient.Version.current()}
      ],
      handle_initial_conn_failure: true,
      max_frame_size: client.max_response_bytes
    ] ++ websocket_tls_options(client)
  end

  defp websocket_tls_options(%{base_url: base_url} = client) do
    case URI.parse(base_url).scheme do
      scheme when scheme in ["https", "wss"] ->
        if client.allow_insecure_websocket_tls? do
          [insecure: true] ++ insecure_ssl_options(client.websocket_tls_options)
        else
          [
            insecure: false,
            ssl_options: secure_ssl_options(base_url, client.websocket_tls_options)
          ]
        end

      _scheme ->
        []
    end
  end

  defp insecure_ssl_options([]), do: []

  defp insecure_ssl_options(options) do
    [ssl_options: Keyword.put(options, :verify, :verify_none)]
  end

  defp secure_ssl_options(base_url, custom_options) do
    host = base_url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
    |> Keyword.merge(custom_options)
    |> Keyword.put(:verify, :verify_peer)
    |> Keyword.put(:server_name_indication, host)
    |> Keyword.put(
      :customize_hostname_check,
      match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
    )
  end

  @impl true
  def handle_connect(conn, state) do
    state = ExironClient.RuntimeStatus.attach(state)

    case connected_state(state, conn) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> exit_disconnected(state, error)
    end
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    if byte_size(payload) > state.client.max_response_bytes do
      error =
        Error.new(
          :invalid_response,
          "websocket frame exceeds configured size limit of " <>
            "#{state.client.max_response_bytes} bytes",
          body: %{
            frame_bytes: byte_size(payload),
            max_response_bytes: state.client.max_response_bytes
          }
        )

      exit_disconnected(state, error)
    else
      handle_text_frame(payload, state)
    end
  end

  defp handle_text_frame(payload, state) do
    state = %{state | last_seen_ms: monotonic_ms()}

    with {:ok, frame} <- Jason.decode(payload),
         {:ok, state} <- handle_socket_frame(frame, state) do
      {:ok, %{state | last_seen_ms: monotonic_ms()}}
    else
      {:recoverable_error, %Error{} = error} ->
        ExironClient.RuntimeStatus.error(state, error)
        {:ok, %{state | last_error: error}}

      {:error, %Error{} = error} ->
        exit_disconnected(state, error)

      {:error, reason} ->
        exit_disconnected(state, reason)
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    if state.client_drain do
      ClientDrain.finish(state, {:error, :disconnected_during_drain})
      exit(:normal)
    end

    state = ExironClient.RuntimeStatus.attach(state)
    error = SocketError.disconnect_error(reason, state)
    state = disconnect(state, error)

    if Error.recoverable_connection_error?(error) or match?(%Error{status: 429}, error) do
      case SocketBackoff.reconnect_after(state, error) do
        {:ok, state} -> {:reconnect, state}
        {:error, error} -> exit(error)
      end
    else
      exit(error)
    end
  end

  @impl true
  def handle_info({:client_drain, from, ref, deadline}, state) do
    case ClientDrain.begin_drain(state, from, ref, deadline) do
      {:ok, state} ->
        if DeliveryWorker.active?(state), do: {:ok, state}, else: finish_drain(state)

      {:error, _reason} ->
        {:ok, state}
    end
  end

  def handle_info({:client_drain_timeout, ref}, %{client_drain: %{ref: ref}} = state) do
    {:close, {1000, "drain timeout"},
     disconnect(
       ClientDrain.finish(state, {:error, :drain_timeout}),
       :drain_timeout
     )}
  end

  def handle_info({:client_drain_timeout, _}, state), do: {:ok, state}

  def handle_info({ref, result}, %{retire_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    complete_drain(%{state | retire_task: nil}, result)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{retire_task: %Task{ref: ref}} = state) do
    exit_disconnected(
      %{state | retire_task: nil},
      Error.new(:request_error, "client retirement failed", body: reason)
    )
  end

  @impl true
  def handle_info(
        {:handler_complete, worker_pid, job_ref},
        %{worker_pid: worker_pid, worker_job_ref: job_ref} = state
      ) do
    {:ok, delivery_id, state} = SocketDelivery.complete(state, worker_pid, job_ref)
    state = if is_binary(delivery_id), do: %{state | last_delivery_id: delivery_id}, else: state

    if state.client_drain do
      finish_drain(state)
    else
      acknowledge_completed(state, delivery_id)
    end
  end

  def handle_info({:handler_complete, _worker_pid, _job_ref}, state), do: {:ok, state}

  def handle_info(
        {:handler_failed, worker_pid, job_ref, reason},
        %{worker_pid: worker_pid, worker_job_ref: job_ref} = state
      ) do
    exit_disconnected(state, reason)
  end

  def handle_info({:handler_failed, _worker_pid, _job_ref, _reason}, state), do: {:ok, state}

  def handle_info(
        {:DOWN, worker_monitor_ref, :process, worker_pid, reason},
        %{worker_pid: worker_pid, worker_monitor_ref: worker_monitor_ref} = state
      ) do
    error = Error.new(:transport_error, "websocket handler worker stopped", body: reason)
    exit_disconnected(state, error)
  end

  def handle_info({:ping, ping_ref}, %{ping_ref: ping_ref} = state) do
    if heartbeat_expired?(state) do
      error = Error.new(:transport_error, "websocket heartbeat timeout")
      state = disconnect(state, error)
      {:ok, state} = SocketLifecycle.transition(state, :close)
      close_connection(state)

      {:close, {4000, "heartbeat timeout"},
       %{
         state
         | connected?: false,
           last_error: error,
           conn: nil,
           ping_timer_ref: nil,
           ping_ref: nil
       }}
    else
      {:reply, {:text, Jason.encode!(%{type: @ping_frame})}, schedule_ping(state)}
    end
  end

  def handle_info({:ping, _timer_ref}, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    try do
      _state = disconnect(state, reason)
      :ok
    after
      if state.retire_task, do: Task.shutdown(state.retire_task, :brutal_kill)
      SocketDelivery.stop(state)
    end
  end

  @impl true
  def format_status(_reason, [_process_dictionary, state]) do
    [data: [{~c"State", status_state(state)}]]
  end

  defp handle_socket_frame(%{"type" => @messages_frame}, %{client_drain: drain} = state)
       when not is_nil(drain), do: {:ok, state}

  defp handle_socket_frame(%{"type" => @messages_frame, "messages" => messages} = frame, state)
       when is_list(messages) do
    valid_id? = is_binary(frame["delivery_id"]) and byte_size(frame["delivery_id"]) in 1..128

    with true <- not state.graceful_shutdown or messages == [] or valid_id?,
         {:ok, messages} <- Message.from_server_list(messages, :request) do
      state = SocketDelivery.ensure_worker(state)

      with {:ok, state} <- pause_connection(state),
           {:ok, state} <-
             SocketDelivery.enqueue(state, messages, Map.get(frame, "delivery_id")) do
        {:ok, state}
      end
    else
      false ->
        {:error, Error.new(:invalid_response, "graceful shutdown requires a batch identity")}

      error ->
        error
    end
  end

  defp handle_socket_frame(
         %{"type" => @connected_frame} = frame,
         %{connected?: false, on_connect: on_connect, on_protocol: on_protocol} = state
       ) do
    with :ok <- ExironClient.RuntimeReporting.session(state, frame["runtime_ref"]),
         {:ok, state} <- SocketLifecycle.transition(state, :server_connected) do
      state = SocketBackoff.reset(state)
      Process.delete(@disconnect_notified_key)
      protocol = Protocol.from_wire(frame)
      ExironClient.RuntimeStatus.connected(state)
      ExironClient.RuntimeStatus.phase(state, :waiting)
      on_protocol.(protocol)
      on_connect.()
      {:ok, Map.put(state, :protocol, protocol)}
    end
  end

  defp handle_socket_frame(%{"type" => @connected_frame}, state), do: {:ok, state}
  defp handle_socket_frame(%{"type" => @pong_frame}, state), do: {:ok, state}

  defp handle_socket_frame(%{"type" => @error_frame, "error" => message} = frame, _state) do
    error = SocketError.socket_error(message, frame)

    if Error.recoverable_connection_error?(error) or match?(%Error{status: 429}, error) do
      {:recoverable_error, error}
    else
      {:error, error}
    end
  end

  defp handle_socket_frame(_frame, state), do: {:ok, state}

  defp connected_state(state, conn) do
    state =
      state
      |> SocketDelivery.ensure_worker()
      |> Map.merge(%{
        conn: conn,
        last_seen_ms: monotonic_ms(),
        last_error: nil,
        socket_paused?: false
      })
      |> transport_connected(conn)
      |> schedule_ping()

    if is_reference(state.worker_job_ref) do
      pause_connection(state)
    else
      {:ok, state}
    end
  end

  defp state!(opts) do
    state = ExironClient.PollerOptions.build!(opts)

    unless is_binary(state.client.token) and state.client.token != "" do
      raise ArgumentError, "websocket transport requires a client token"
    end

    struct!(
      SocketState,
      Map.merge(state, %{
        last_seen_ms: monotonic_ms(),
        socket_transport: socket_transport!(opts)
      })
    )
  end

  defp disconnect(%{connected?: true, on_disconnect: on_disconnect} = state, reason) do
    ExironClient.RuntimeStatus.disconnected(state, reason)
    # A callback can exit before its updated state reaches SocketTransport.
    # Keep the notification guard in the owning process across that exit and
    # termination; a server-accepted reconnect starts a new notification cycle.
    unless Process.get(@disconnect_notified_key, false) do
      Process.put(@disconnect_notified_key, true)
      on_disconnect.(reason)
    end

    {:ok, state} = SocketLifecycle.transition(state, {:disconnect, reason})
    state
  end

  defp disconnect(state, reason) do
    ExironClient.RuntimeStatus.disconnected(state, reason)
    {:ok, state} = SocketLifecycle.transition(state, {:disconnect, reason})
    state
  end

  defp exit_disconnected(%{client_drain: drain} = state, reason) when not is_nil(drain) do
    state = ClientDrain.finish(state, {:error, reason})
    _ = disconnect(state, reason)
    exit(:normal)
  end

  defp exit_disconnected(state, reason) do
    _state = disconnect(state, reason)
    exit(reason)
  end

  @doc false
  def reconnect_delay_ms(state, error),
    do: ReconnectPolicy.delay_ms(state.client.reconnect_backoff, error)

  defp schedule_ping(state) do
    if is_reference(Map.get(state, :ping_timer_ref)) do
      Process.cancel_timer(state.ping_timer_ref)
    end

    ping_ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:ping, ping_ref}, max(div(state.disconnect_timeout_ms, 2), 1))

    %{state | ping_ref: ping_ref, ping_timer_ref: timer_ref}
  end

  defp acknowledge_completed(state, delivery_id) do
    case resume_connection(state) do
      {:ok, state} when is_binary(delivery_id) ->
        {:reply, acknowledgement_frame(delivery_id), state}

      {:ok, state} ->
        {:ok, state}

      {:error, error} ->
        exit_disconnected(state, error)
    end
  end

  defp finish_drain(%{last_delivery_id: nil} = state),
    do:
      complete_drain(
        state,
        ClientDrain.retire(state.client, nil, state.client_drain)
      )

  defp finish_drain(state) do
    budget = max(state.client_drain.deadline - ClientDrain.now(), 0)

    if budget == 0 do
      complete_drain(state, {:error, :drain_timeout})
    else
      client = state.client
      id = state.last_delivery_id
      task = Task.async(fn -> ClientDrain.request(client, id, budget) end)

      case resume_connection(%{state | retire_task: task}) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          Task.shutdown(task, :brutal_kill)
          exit_disconnected(state, reason)
      end
    end
  end

  defp complete_drain(state, result) do
    {:close, {1000, "drained"}, disconnect(ClientDrain.finish(state, result), :normal)}
  end

  defp heartbeat_expired?(%{worker_job_ref: worker_job_ref})
       when is_reference(worker_job_ref),
       do: false

  defp heartbeat_expired?(state) do
    monotonic_ms() - state.last_seen_ms >= state.disconnect_timeout_ms
  end

  defp pause_connection(%{socket_paused?: true} = state), do: {:ok, state}

  defp pause_connection(%{conn: %WebSockex.Conn{} = conn} = state) do
    case apply(socket_transport(state), :set_active, [conn, false]) do
      :ok -> SocketLifecycle.transition(state, :pause)
      {:error, reason} -> {:error, connection_flow_error("pause", reason)}
    end
  end

  defp pause_connection(state), do: SocketLifecycle.transition(state, :pause)

  defp resume_connection(%{socket_paused?: true, conn: %WebSockex.Conn{} = conn} = state) do
    case apply(socket_transport(state), :set_active, [conn, :once]) do
      :ok -> SocketLifecycle.transition(state, :resume)
      {:error, reason} -> {:error, connection_flow_error("resume", reason)}
    end
  end

  defp resume_connection(state) do
    if SocketLifecycle.connection_state(state) == :paused do
      SocketLifecycle.transition(state, :resume)
    else
      {:ok, %{state | socket_paused?: false}}
    end
  end

  defp transport_connected(state, conn) do
    {:ok, state} = SocketLifecycle.transition(state, {:transport_connected, conn})
    state
  end

  defp socket_transport(state), do: Map.get(state, :socket_transport, SocketTransport)

  defp socket_transport!(opts) do
    transport = Keyword.get(opts, :socket_transport, SocketTransport)

    if is_atom(transport) and match?({:module, _module}, Code.ensure_loaded(transport)) and
         function_exported?(transport, :start_link, 4) and
         function_exported?(transport, :set_active, 2) do
      transport
    else
      raise ArgumentError,
            ":socket_transport must implement ExironClient.SocketTransportBehaviour"
    end
  end

  defp connection_flow_error(action, reason) do
    Error.new(:transport_error, "failed to #{action} websocket reads", body: reason)
  end

  defp acknowledgement_frame(delivery_id) do
    {:text, Jason.encode!(%{type: @ack_frame, delivery_id: delivery_id})}
  end

  defp status_state(%SocketState{} = state) do
    %{
      client: ExironClient.OTPStatus.client(state.client),
      connected?: state.connected?,
      connection_state: SocketLifecycle.connection_state(state),
      last_seen_ms: state.last_seen_ms,
      reconnect_started_at_ms: state.reconnect_started_at_ms,
      worker_pid: state.worker_pid,
      worker_active?: is_reference(state.worker_job_ref),
      socket_paused?: state.socket_paused?,
      protocol: state.protocol
    }
  end

  defp status_state(_state), do: :redacted

  defp close_connection(%{conn: %WebSockex.Conn{} = conn}) do
    WebSockex.Conn.close_socket(conn)
    :ok
  end

  defp close_connection(_state), do: :ok

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  @doc false
  def socket_url(client), do: SocketUrl.build(client)
end
