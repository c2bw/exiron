defmodule ExironClient.GracefulHTTPPoller do
  @moduledoc false
  use GenServer
  alias ExironClient.{ClientDrain, DeliveryWorker, Error}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(opts) do
    config = opts |> ExironClient.PollerOptions.build!() |> ExironClient.RuntimeStatus.attach()

    wrapper = fn messages, id, handler, handler_options ->
      ExironClient.HTTPLease.handle(
        %{delivery_id: id, messages: messages},
        config,
        fn lease_opts ->
          ExironClient.MessageHandler.handle(
            messages,
            handler,
            Keyword.merge(handler_options, lease_opts) |> Keyword.put(:delivery_id, id)
          )
        end
      )
    end

    state =
      config
      |> Map.merge(%{
        worker_pid: nil,
        worker_monitor_ref: nil,
        worker_job_ref: nil,
        worker_delivery_id: nil,
        delivery_ack: nil,
        last_delivery_id: nil,
        connected?: false,
        client_drain: nil,
        retry_delay_ms: nil,
        poll_task: nil
      })
      |> DeliveryWorker.ensure_started(
        Keyword.put(config.handler_options, :batch_wrapper, wrapper)
      )

    {:ok, state, {:continue, :poll}}
  end

  def handle_continue(:poll, state), do: poll(state)
  def handle_info(:poll, %{client_drain: drain} = state) when not is_nil(drain), do: finish(state)

  def handle_info(:poll, %{worker_job_ref: ref} = state) when is_reference(ref),
    do: {:noreply, state}

  def handle_info(:poll, state), do: poll(state)

  def handle_info({:client_drain, from, ref, deadline}, state) do
    case ClientDrain.begin_drain(state, from, ref, deadline) do
      {:ok, state} ->
        if DeliveryWorker.active?(state), do: {:noreply, state}, else: finish(state)

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:client_drain_timeout, ref}, %{client_drain: %{ref: ref}} = state) do
    {:stop, :normal, ClientDrain.finish(state, {:error, :drain_timeout})}
  end

  def handle_info({:client_drain_timeout, _}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{poll_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | poll_task: nil}
    if state.client_drain, do: finish(state), else: poll_result(state, result)
  end

  def handle_info({:handler_complete, pid, ref}, %{worker_pid: pid, worker_job_ref: ref} = state) do
    {:ok, id, state} = DeliveryWorker.complete(state, pid, ref)
    state = %{state | delivery_ack: id, last_delivery_id: id}

    if state.client_drain do
      finish(state)
    else
      ExironClient.RuntimeStatus.phase(state, :waiting)
      Process.send_after(self(), :poll, state.interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(
        {:handler_failed, pid, ref, reason},
        %{worker_pid: pid, worker_job_ref: ref} = state
      ) do
    stop_worker(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{worker_monitor_ref: ref} = state) do
    stop_worker(state, reason)
  end

  def terminate(reason, state) do
    if state.poll_task, do: Task.shutdown(state.poll_task, :brutal_kill)
    DeliveryWorker.stop(state)
    ExironClient.RuntimeStatus.disconnected(state, reason)
    if state.connected?, do: state.on_disconnect.(reason)
  end

  def format_status(status),
    do:
      ExironClient.OTPStatus.redact(status, fn state ->
        %{
          client: ExironClient.OTPStatus.client(state.client),
          draining?: not is_nil(state.client_drain),
          active?: is_reference(state.worker_job_ref)
        }
      end)

  defp poll(%{poll_task: %Task{}} = state), do: {:noreply, state}

  defp poll(state) do
    ExironClient.RuntimeStatus.phase(state, :polling)
    budget = max(state.disconnect_timeout_ms - state.interval_ms, 1)

    client = state.client

    client =
      put_in(
        client.reconnect_backoff[:max_retry_time_ms],
        min(client.reconnect_backoff[:max_retry_time_ms], budget)
      )

    ack = state.delivery_ack

    task =
      Task.async(fn ->
        try do
          ExironClient.requests_delivery(client, ack, receive_timeout: budget)
        rescue
          _ -> {:error, Error.new(:request_error, "HTTP polling failed")}
        catch
          _, _ -> {:error, Error.new(:request_error, "HTTP polling failed")}
        end
      end)

    {:noreply, %{state | poll_task: task}}
  end

  defp poll_result(state, result) do
    case result do
      {:ok, %{delivery_id: id, messages: messages} = delivery} ->
        state =
          if state.connected?,
            do: state,
            else:
              (
                ExironClient.RuntimeStatus.connected(state)
                state.on_connect.()
                %{state | connected?: true}
              )

        session = ExironClient.RuntimeReporting.session(state, Map.get(delivery, :runtime_ref))

        cond do
          match?({:error, _}, session) ->
            {:error, error} = session
            {:stop, error, state}

          messages == [] ->
            ExironClient.RuntimeStatus.phase(state, :waiting)
            Process.send_after(self(), :poll, state.interval_ms)
            {:noreply, %{state | delivery_ack: nil, retry_delay_ms: nil}}

          not is_binary(id) or id == "" ->
            {:stop, Error.new(:invalid_response, "graceful shutdown requires a batch identity"),
             state}

          true ->
            {:ok, state} = DeliveryWorker.enqueue(state, messages, id)
            {:noreply, %{state | retry_delay_ms: nil}}
        end

      {:error, error} ->
        ExironClient.RuntimeStatus.disconnected(state, error)

        if Error.recoverable_connection_error?(error) do
          if state.connected?, do: state.on_disconnect.(error)
          base = state.retry_delay_ms || state.interval_ms
          backoff = Keyword.put(state.client.reconnect_backoff, :current_delay_ms, base)
          delay = ExironClient.ReconnectPolicy.delay_ms(backoff, error)
          ExironClient.RuntimeStatus.phase(state, :backing_off, delay)
          Process.send_after(self(), :poll, delay)

          {:noreply,
           %{state | connected?: false, retry_delay_ms: min(base * 2, backoff[:max_delay_ms])}}
        else
          {:stop, error, state}
        end
    end
  end

  defp finish(state) do
    result = ClientDrain.retire(state.client, state.last_delivery_id, state.client_drain)
    {:stop, :normal, ClientDrain.finish(state, result)}
  end

  defp stop_worker(state, reason) do
    {:stop, if(state.client_drain, do: :normal, else: reason),
     ClientDrain.finish(state, {:error, reason})}
  end
end
