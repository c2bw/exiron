defmodule Exiron.Hub.ClientSessions do
  @moduledoc false

  alias Exiron.Hub.{
    ClientDeliveries,
    ClientEventLog,
    ClientLeases,
    ClientSession,
    ClientState,
    Router
  }

  def poll(state, hook, opts) do
    with {:ok, state} <- ClientLeases.touch(state, hook, opts) do
      state = put_in(state.delivery.clients[hook].http_batch_ref, nil)
      {items, state} = drain_queue(state, hook)
      {:ok, items, Exiron.Hub.ClientPresence.contact(state, hook, :poll)}
    end
  end

  def poll_delivery(state, hook, opts) do
    with {:ok, state} <- ClientLeases.touch(state, hook, opts),
         {:ok, delivery_id, items, state} <-
           ClientDeliveries.poll_delivery(state, hook, Keyword.get(opts, :delivery_ack)) do
      state =
        state |> record_client_connect(hook) |> Exiron.Hub.ClientPresence.contact(hook, :poll)

      {:ok,
       %{
         delivery_id: delivery_id,
         runtime_ref: state.delivery.clients[hook].runtime_ref,
         requests: items
       }, state}
    end
  end

  def connect_socket(state, hook, opts) do
    with {:ok, state} <- ClientLeases.connect_socket(state, hook, opts) do
      state =
        state |> record_client_connect(hook) |> Exiron.Hub.ClientPresence.contact(hook, :connect)

      {delivery_ref, items, state} = start_socket_delivery(state, hook)

      {:ok,
       %{
         hook: hook,
         client_id: Keyword.fetch!(opts, :client_id),
         runtime_ref: state.delivery.clients[hook].runtime_ref,
         listen: Keyword.get(opts, :listen, false),
         delivery_ref: delivery_ref,
         messages: items
       }, state}
    end
  end

  def disconnect_socket(state, hook, client_id, pid) do
    case Map.get(state.delivery.clients, hook) do
      %{client_id: ^client_id, pid: ^pid, transport: :websocket} = client ->
        state
        |> ClientLeases.disconnect_socket(hook, client_id, pid)
        |> ClientEventLog.record("disconnected", hook, client)

      _client ->
        state
    end
  end

  def disconnect_down_socket(state, monitor, pid) do
    case Enum.find(state.delivery.clients, fn
           {_hook, %{transport: :websocket, pid: client_pid, monitor: client_monitor}}
           when client_pid == pid and client_monitor == monitor ->
             true

           _client ->
             false
         end) do
      {hook, %{client_id: client_id}} ->
        {:disconnected, disconnect_socket(state, hook, client_id, pid)}

      nil ->
        {:unchanged, state}
    end
  end

  def expire_client(state, hook, client_id, lease) do
    expired_client = Map.get(state.delivery.clients, hook)

    state
    |> ClientLeases.expire(hook, client_id, lease)
    |> record_client_disconnect(hook, client_id, lease, expired_client)
  end

  def deliver_socket_queues(state) do
    state.delivery.clients
    |> Enum.filter(&socket_client?/1)
    |> Enum.reduce(state, &deliver_socket_queue/2)
  end

  def complete_socket_delivery(state, hook, client_id, pid, delivery_ref) do
    case ClientDeliveries.complete_socket_delivery(state, hook, client_id, pid, delivery_ref) do
      {:completed, state} ->
        {:completed, Exiron.Hub.ClientPresence.socket_contact(state, hook, client_id, pid, :ack)}

      other ->
        other
    end
  end

  def reset(state) do
    state =
      state
      |> release_resources()
      |> disconnect_socket_clients()
      |> record_reload_disconnects()

    state =
      Enum.reduce(Map.keys(state.delivery.pending), state, fn id, acc ->
        Exiron.Hub.RequestTrace.record(acc, id, :client_sessions_reset, status: :failed)
      end)

    delivery = %{state.delivery | queues: %{}, clients: %{}, client_presence: %{}, pending: %{}}
    %{state | delivery: delivery}
  end

  def reconcile_router(state, %Router{} = old_router, %Router{} = new_router) do
    state =
      state.delivery.clients
      |> Map.keys()
      |> Enum.reject(&hook_credentials_unchanged?(old_router, new_router, &1))
      |> Enum.reduce(state, &disconnect_client/2)

    prune_removed_hooks(state, new_router)
  end

  def release_resources(state) do
    Enum.each(state.delivery.clients, fn {_hook, client} ->
      ClientLeases.release_resources(client)
    end)

    Enum.each(state.delivery.pending, fn
      {_request_id, %{timer: timer}} when is_reference(timer) -> Process.cancel_timer(timer)
      _request -> :ok
    end)

    state
  end

  defp drain_queue(state, hook) do
    state = record_client_connect(state, hook)
    {items, state} = ClientDeliveries.drain_queue(state, hook)

    {items, state}
  end

  defp record_client_connect(state, hook) do
    case Map.fetch!(state.delivery.clients, hook) do
      %{connected_at: nil} = client ->
        state
        |> update_in([Access.key!(:delivery), Access.key!(:clients), hook], fn
          %ClientSession{} = client -> %{client | connected_at: DateTime.utc_now()}
          client -> put_in(client, [:connected_at], DateTime.utc_now())
        end)
        |> ClientEventLog.record("connected", hook, client)

      _client ->
        state
    end
  end

  defp record_client_disconnect(state, hook, client_id, lease, client) do
    case client do
      %{client_id: ^client_id, lease: ^lease} ->
        ClientEventLog.record(state, "disconnected", hook, client)

      _client ->
        state
    end
  end

  defp socket_client?({_hook, client}), do: client.transport == :websocket and is_pid(client.pid)

  defp deliver_socket_queue({hook, client}, state) do
    case ClientDeliveries.start_socket_delivery(state, hook) do
      {:ok, delivery_ref, items, state} ->
        send(client.pid, {:exiron_messages, delivery_ref, items})
        state

      {_status, state} ->
        state
    end
  end

  defp start_socket_delivery(state, hook) do
    case ClientDeliveries.start_socket_delivery(state, hook) do
      {:ok, delivery_ref, items, state} -> {delivery_ref, items, state}
      {_status, state} -> {nil, [], state}
    end
  end

  defp disconnect_socket_clients(state) do
    Enum.each(state.delivery.clients, fn {_hook, client} ->
      notify_socket_replaced(client)
    end)

    state
  end

  defp disconnect_client(hook, state) do
    case Map.fetch(state.delivery.clients, hook) do
      {:ok, client} ->
        notify_socket_replaced(client)
        :ok = ClientLeases.release_resources(client)

        state
        |> ClientState.remove(hook)
        |> ClientEventLog.record("disconnected", hook, client)

      :error ->
        state
    end
  end

  defp notify_socket_replaced(%{pid: pid, transport: :websocket}) when is_pid(pid),
    do: send(pid, {:exiron_socket_replaced, self()})

  defp notify_socket_replaced(_client), do: :ok

  defp hook_credentials_unchanged?(old_router, new_router, hook) do
    case Map.fetch(old_router.hooks, hook) do
      {:ok, token} -> Map.get(new_router.hooks, hook) == token
      :error -> false
    end
  end

  defp prune_removed_hooks(state, %Router{} = router) do
    retained_hooks = Map.keys(router.hooks)
    retained_hook_set = MapSet.new(retained_hooks)

    pending =
      Enum.reduce(state.delivery.pending, %{}, fn {request_id, request}, retained ->
        if MapSet.member?(retained_hook_set, Map.get(request, :hook)) do
          Map.put(retained, request_id, request)
        else
          cancel_pending_timer(request)
          retained
        end
      end)

    removed = Map.keys(state.delivery.pending) -- Map.keys(pending)

    state =
      Enum.reduce(removed, state, fn id, acc ->
        Exiron.Hub.RequestTrace.record(acc, id, :hook_removed, status: :failed)
      end)

    delivery = %{
      state.delivery
      | queues: Map.take(state.delivery.queues, retained_hooks),
        pending: pending,
        client_presence: Map.take(state.delivery.client_presence, retained_hooks)
    }

    %{state | delivery: delivery, health: Map.take(state.health, retained_hooks)}
  end

  defp cancel_pending_timer(%{timer: timer}) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_pending_timer(_request), do: :ok

  defp record_reload_disconnects(state) do
    Enum.reduce(state.delivery.clients, state, fn {hook, client}, acc ->
      ClientEventLog.record(acc, "disconnected", hook, client)
    end)
  end
end
