defmodule ExironClient.Poller do
  @moduledoc """
  Supervised polling loop for an `ExironClient`.

  The poller calls `ExironClient.requests/1` on an interval and passes each
  message to the configured handler. Handler calls are serial by default. Return
  `{:error, reason}` from the handler to stop the poller; any other return value
  is treated as success.

  Optional lifecycle callbacks report when the managed client starts and stops
  maintaining its lease. `:on_connect` runs after the server confirms a
  WebSocket connection, or after the first successful HTTP poll in a connected
  stretch. `:on_disconnect` runs with the stop reason when a previously
  connected poller exits or loses polling. Transport outages and
  hook-takeover conflicts are recoverable; after reporting disconnect, the
  poller keeps retrying until a connection succeeds or a fatal error occurs.
  """

  use GenServer

  alias ExironClient.Error

  @type handler :: (ExironClient.Message.t() -> term())
  @type connect_handler :: (-> term())
  @type disconnect_handler :: (term() -> term())

  @doc """
  Starts a managed polling process.

  ## Options

    * `:client` - required `ExironClient` struct.
    * `:handler` - required one-argument function called for each message.
    * `:interval_ms` - delay after each successful poll. Defaults to `1000`.
    * `:disconnect_timeout_ms` - target maximum time after the previous
      healthy poll before recoverable polling failures are reported as
      disconnected. Defaults to `2000`.
    * `:http_lease_renewal` - opt in to owned-batch lease renewal during HTTP
      handlers. Defaults to false; requires server support. Lost renewal signals
      handlers and stops dispatch without acknowledging the batch.
    * `:runtime_reporting` - five-second background runtime reports for the monitor.
      Defaults to `:auto`: enable when discovery advertises server support. Set
      `false` to opt out, or `true` to require support. Reports do not renew leases
      or acknowledge work.
    * `:handler_timeout_ms` - total per-message execution/retry budget; 0 disables it.
      Expiry is cooperative and does not kill or acknowledge an unfinished handler.
      Use ExironClient.HandlerDeadline.current/0 inside the handler.
    * `:handler_failure_policy` - :stop (default) or :quarantine. Quarantine
      requires a separately supervised :quarantine store and makes the poller
      child spec :temporary, so fatal failures await explicit operator recovery.
    * `:quarantine` - PID of a running ExironClient.Quarantine store.
    * `:on_quarantined` - one-argument callback receiving retained metadata.
    * `:handler_concurrency` - 1..64 messages in parallel within a batch; defaults to 1.
      Values above 1 run handlers in separate tasks and require concurrency-safe callbacks.
      On exhaustion, active siblings finish and the batch remains unacknowledged.
    * `:handler_order_by_chat` - preserve batch order for each service/chat/topic
      when concurrency exceeds 1. Defaults to false; unrelated conversations run in parallel.
    * `:handler_max_attempts` - 1..10 attempts per message; defaults to 1.
      Additional attempts retry the failing message locally before batch acknowledgement.
    * `:handler_retry_delay_ms` - positive retry delay; defaults to 250.
    * `:on_handler_error` - callback receiving request_id, attempt, max_attempts,
      will_retry? and reason for each failed attempt. Defaults to no-op.
    * `:report_handler_failures` - opt in to bounded retry/exhaustion/recovery
      reports for the monitor. Defaults to false; errors and bodies stay local.
    * `:cooperative_cancellation` - opt in to server cancellation/expiry signals
      for running handlers. Defaults to false; requires server capability support.
    * `:cancellation_interval_ms` - state check interval, at least 100; defaults to 1000.
    * `:on_request_cancelled` - optional prompt callback receiving request_id and
      reason (:cancelled or :expired). See `ExironClient.Cancellation`.
    * `:on_connect` - zero-argument function called after the server confirms a
      WebSocket connection, or after the first successful HTTP poll. Defaults
      to no-op.
    * `:on_protocol` - one-argument function called with
      `ExironClient.Protocol` metadata from a WebSocket connected frame,
      immediately before `:on_connect`. Defaults to no-op.
    * `:on_disconnect` - one-argument function called with the stop reason when
      a previously connected poller stops. Defaults to no-op.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :transport, :websocket) do
      :websocket ->
        ExironClient.SocketPoller.start_link(opts)

      :http ->
        if Keyword.get(opts, :graceful_shutdown, false) == true,
          do: ExironClient.GracefulHTTPPoller.start_link(opts),
          else: GenServer.start_link(__MODULE__, opts)

      transport ->
        raise ArgumentError, ":transport must be :websocket or :http, got: #{inspect(transport)}"
    end
  end

  @doc "Finish the current batch and retire without fetching more work; requires :graceful_shutdown."
  def drain(pid, timeout_ms \\ 30_000), do: ExironClient.ClientDrain.drain(pid, timeout_ms)

  @doc "Read a sanitized local snapshot without waiting for handlers or network I/O. Returns {:error, :not_running} after exit."
  @spec status(pid()) :: {:ok, map()} | {:error, :not_running}
  def status(pid) when is_pid(pid), do: ExironClient.RuntimeStatus.read(pid)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart:
        cond do
          Keyword.get(opts, :handler_failure_policy, :stop) == :quarantine -> :temporary
          Keyword.get(opts, :graceful_shutdown, false) == true -> :transient
          true -> :permanent
        end
    }
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> ExironClient.PollerOptions.build!()
      |> ExironClient.RuntimeStatus.attach()
      |> Map.merge(%{connected?: false, delivery_ack: nil, retry_delay_ms: nil})

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: poll(state)

  @impl true
  def handle_info(:poll, state), do: poll(state)

  def handle_info({:client_drain, from, ref, deadline}, state) do
    {:error, :graceful_shutdown_disabled} =
      ExironClient.ClientDrain.begin_drain(state, from, ref, deadline)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    disconnect(state, reason)
    :ok
  end

  @impl true
  def format_status(status) do
    ExironClient.OTPStatus.redact(status, &status_state/1)
  end

  defp poll(state) do
    ExironClient.RuntimeStatus.phase(state, :polling)

    case ExironClient.requests_delivery(
           poll_client(state),
           state.delivery_ack,
           poll_request_opts(state)
         ) do
      {:ok, delivery} ->
        %{state | retry_delay_ms: nil}
        |> connect()
        |> handle_delivery(delivery)

      {:error, %Error{} = error} ->
        handle_poll_error(state, error)

      {:error, reason} ->
        {:stop, reason, disconnect(state, reason)}
    end
  end

  defp handle_delivery(state, delivery) do
    result =
      with :ok <- ExironClient.RuntimeReporting.session(state, Map.get(delivery, :runtime_ref)) do
        handle_delivery_batch(state, delivery)
      end

    case result do
      :ok ->
        ExironClient.RuntimeStatus.phase(state, :waiting)
        Process.send_after(self(), :poll, state.interval_ms)
        {:noreply, %{state | delivery_ack: delivery.delivery_id}}

      {:error, reason} ->
        {:stop, reason, disconnect(state, reason)}
    end
  end

  defp handle_delivery_batch(state, delivery) do
    result =
      ExironClient.HTTPLease.handle(delivery, state, fn handler_options ->
        ExironClient.MessageHandler.handle(
          delivery.messages,
          state.handler,
          Keyword.put(handler_options, :delivery_id, delivery.delivery_id)
        )
      end)

    result
  end

  defp handle_poll_error(state, %Error{} = error) do
    if Error.recoverable_connection_error?(error) do
      state = disconnect(state, error)
      base = state.retry_delay_ms || state.interval_ms
      backoff = Keyword.put(state.client.reconnect_backoff, :current_delay_ms, base)
      delay = ExironClient.ReconnectPolicy.delay_ms(backoff, error)
      next = min(base * 2, Keyword.fetch!(backoff, :max_delay_ms))
      ExironClient.RuntimeStatus.phase(state, :backing_off, delay)
      Process.send_after(self(), :poll, delay)
      {:noreply, %{state | retry_delay_ms: next}}
    else
      {:stop, error, disconnect(state, error)}
    end
  end

  defp poll_client(state) do
    max_retry_time_ms =
      min(
        Keyword.fetch!(state.client.reconnect_backoff, :max_retry_time_ms),
        poll_retry_timeout_ms(state)
      )

    %{
      state.client
      | reconnect_backoff:
          Keyword.put(
            state.client.reconnect_backoff,
            :max_retry_time_ms,
            max_retry_time_ms
          )
    }
  end

  defp poll_request_opts(state) do
    [receive_timeout: poll_retry_timeout_ms(state)]
  end

  defp poll_retry_timeout_ms(state) do
    timeout_ms = state.disconnect_timeout_ms - state.interval_ms

    if timeout_ms > 0 do
      timeout_ms
    else
      1
    end
  end

  defp connect(%{connected?: false, on_connect: on_connect} = state) do
    ExironClient.RuntimeStatus.connected(state)
    on_connect.()
    %{state | connected?: true}
  end

  defp connect(state), do: state

  defp disconnect(%{connected?: true, on_disconnect: on_disconnect} = state, reason) do
    ExironClient.RuntimeStatus.disconnected(state, reason)
    on_disconnect.(reason)
    %{state | connected?: false}
  end

  defp disconnect(state, reason) do
    ExironClient.RuntimeStatus.disconnected(state, reason)
  end

  defp status_state(state) when is_map(state) do
    %{
      client: ExironClient.OTPStatus.client(state.client),
      interval_ms: state.interval_ms,
      disconnect_timeout_ms: state.disconnect_timeout_ms,
      connected?: state.connected?
    }
  end

  defp status_state(_state), do: :redacted
end
