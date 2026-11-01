defmodule Exiron.Hub.ClientState do
  @moduledoc false

  alias Exiron.Hub.{ClientDeliveries, ClientSession, QueueBuffer}

  def get(state, hook), do: Map.get(state.delivery.clients, hook)

  def timer(state, hook) do
    case get(state, hook) do
      %ClientSession{timer: timer} when is_reference(timer) -> {:ok, timer}
      _client -> :error
    end
  end

  def connected_at(state, hook) do
    state.delivery.clients
    |> Map.get(hook, %{})
    |> Map.get(:connected_at)
  end

  def put(state, hook, client_id, listen, lease, timer, opts \\ []) do
    connected_at = Keyword.get_lazy(opts, :connected_at, fn -> connected_at(state, hook) end)
    listen_mode = listen_mode(listen)

    client =
      ClientSession.new(
        client_id,
        lease,
        timer,
        transport: Keyword.get(opts, :transport, :http),
        client_identity: Keyword.get(opts, :client_identity),
        pid: Keyword.get(opts, :pid),
        monitor: Keyword.get(opts, :monitor),
        http_delivery: existing_http_delivery(state, hook, client_id),
        http_batch_ref: existing_http_batch(state, hook, client_id),
        last_ack_ref: existing_http_ack(state, hook, client_id),
        runtime_ref:
          Keyword.get_lazy(opts, :runtime_ref, fn -> runtime_ref(state, hook, client_id, opts) end),
        listen?: listen_mode != false,
        listen_mode: listen_mode,
        connected_at: connected_at
      )

    delivery = %{
      state.delivery
      | queues: Map.put_new(state.delivery.queues, hook, QueueBuffer.new()),
        clients: Map.put(state.delivery.clients, hook, client)
    }

    %{state | delivery: delivery}
  end

  def ensure_available(state, hook, client_id) do
    case get(state, hook) do
      nil -> :ok
      %{client_id: ^client_id} -> :ok
      client -> {:error, {:hook_already_connected, retry_after_ms(state, client)}}
    end
  end

  def remove(state, hook) do
    state = ClientDeliveries.requeue_unacknowledged(state, hook)
    state = Exiron.Hub.ClientPresence.disconnected(state, hook, get(state, hook))
    %{state | delivery: %{state.delivery | clients: Map.delete(state.delivery.clients, hook)}}
  end

  # Preserve the former internal API while delivery behavior lives in one module.
  defdelegate drain_queue(state, hook), to: ClientDeliveries
  defdelegate start_socket_delivery(state, hook), to: ClientDeliveries
  defdelegate poll_delivery(state, hook, acknowledgement), to: ClientDeliveries

  defdelegate complete_socket_delivery(state, hook, client_id, pid, delivery_ref),
    to: ClientDeliveries

  def retry_after_ms(_state, %ClientSession{timer: timer}) when is_reference(timer) do
    case Process.read_timer(timer) do
      remaining when is_integer(remaining) -> max(remaining, 1)
      false -> 1
    end
  end

  def retry_after_ms(state, _client), do: state.settings.client_timeout

  defp runtime_ref(state, hook, id, opts) do
    case {get(state, hook), Keyword.get(opts, :transport, :http)} do
      {%ClientSession{client_id: ^id, transport: :http, runtime_ref: ref}, :http}
      when is_binary(ref) ->
        ref

      _ ->
        :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    end
  end

  defp existing_http_ack(state, hook, client_id) do
    case get(state, hook) do
      %ClientSession{client_id: ^client_id, transport: :http, last_ack_ref: ref} -> ref
      _ -> nil
    end
  end

  defp existing_http_batch(state, hook, client_id) do
    case get(state, hook) do
      %ClientSession{client_id: ^client_id, transport: :http, http_batch_ref: ref} -> ref
      _ -> nil
    end
  end

  defp existing_http_delivery(state, hook, client_id) do
    case get(state, hook) do
      %ClientSession{client_id: ^client_id, transport: :http, http_delivery: delivery} -> delivery
      _client -> nil
    end
  end

  defp listen_mode(:all), do: :all
  defp listen_mode("all"), do: :all
  defp listen_mode(true), do: true
  defp listen_mode(_listen), do: false
end
