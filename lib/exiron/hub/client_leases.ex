defmodule Exiron.Hub.ClientLeases do
  @moduledoc false

  alias Exiron.Hub.ClientState

  def touch(state, hook, opts) do
    with {:ok, client_id} <- client_id(opts),
         {:ok, state} <- touch(state, hook, client_id, Keyword.get(opts, :listen, false)) do
      identity = Exiron.Hub.ClientIdentity.normalize(Keyword.get(opts, :client_identity))
      {:ok, put_in(state.delivery.clients[hook].client_identity, identity)}
    end
  end

  def renew(state, hook, client_id, batch) do
    with true <- is_binary(client_id) and byte_size(client_id) in 1..128,
         true <- is_binary(batch) and byte_size(batch) in 1..128 do
      case ClientState.get(state, hook) do
        %{transport: :http, client_id: ^client_id, http_batch_ref: ^batch, timer: timer} = client ->
          remaining = if is_reference(timer), do: Process.read_timer(timer), else: false

          if is_integer(remaining) and remaining > 0 do
            Process.cancel_timer(timer)
            lease = make_ref()

            timer =
              Process.send_after(
                self(),
                {:expire_client, hook, client_id, lease},
                state.settings.client_timeout
              )

            state = put_in(state.delivery.clients[hook], %{client | timer: timer, lease: lease})
            state = Exiron.Hub.ClientPresence.contact(state, hook, :lease_renewal)
            {:ok, %{ok: true, lease_timeout_ms: state.settings.client_timeout}, state}
          else
            {:error, :client_lease_lost}
          end

        _ ->
          {:error, :client_lease_lost}
      end
    else
      false -> {:error, :invalid_payload}
    end
  end

  def connect_socket(state, hook, opts) do
    with {:ok, client_id} <- client_id(opts),
         pid when is_pid(pid) <- Keyword.get(opts, :pid),
         :ok <- ClientState.ensure_available(state, hook, client_id) do
      connected_at = ClientState.connected_at(state, hook)
      state = replace_existing_socket(state, hook, client_id, pid)
      monitor = Process.monitor(pid)

      {:ok,
       ClientState.put(
         state,
         hook,
         client_id,
         Keyword.get(opts, :listen, false),
         make_ref(),
         nil,
         transport: :websocket,
         client_identity: Keyword.get(opts, :client_identity),
         pid: pid,
         monitor: monitor,
         connected_at: connected_at
       )}
    else
      nil -> {:error, :invalid_client_id}
      error -> error
    end
  end

  def disconnect_socket(state, hook, client_id, pid) do
    remove_client_if(state, hook, &socket_client?(&1, client_id, pid))
  end

  def expire(state, hook, client_id, lease) do
    remove_client_if(state, hook, &leased_client?(&1, client_id, lease))
  end

  defp remove_client_if(state, hook, fun) do
    client = ClientState.get(state, hook)

    if fun.(client), do: remove_client(state, hook, client), else: state
  end

  defp socket_client?(%{client_id: client_id, pid: pid, transport: :websocket}, client_id, pid),
    do: true

  defp socket_client?(_client, _client_id, _pid), do: false

  defp leased_client?(%{client_id: client_id, lease: lease}, client_id, lease), do: true
  defp leased_client?(_client, _client_id, _lease), do: false

  defp replace_existing_socket(state, hook, client_id, pid) do
    case ClientState.get(state, hook) do
      %{client_id: ^client_id, pid: old_pid, transport: :websocket} = client ->
        if old_pid != pid, do: send(old_pid, {:exiron_socket_replaced, pid})
        remove_client(state, hook, client)

      %{client_id: ^client_id, timer: timer} = client when is_reference(timer) ->
        remove_client(state, hook, client)

      _client ->
        state
    end
  end

  def release_resources(client) when is_map(client) do
    cancel_timer(Map.get(client, :timer))
    demonitor(Map.get(client, :monitor))
    :ok
  end

  def release_resources(_client), do: :ok

  defp remove_client(state, hook, client) do
    :ok = release_resources(client)
    ClientState.remove(state, hook)
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp demonitor(monitor) when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp demonitor(_monitor), do: :ok

  defp touch(state, hook, client_id, listen?) do
    with :ok <- ensure_http_poll_available(state, hook, client_id) do
      connected_at = ClientState.connected_at(state, hook)
      previous = ClientState.get(state, hook)

      runtime_ref =
        case previous do
          %{client_id: ^client_id, transport: :http, timer: old_timer, runtime_ref: ref}
          when is_reference(old_timer) and is_binary(ref) ->
            if (Process.read_timer(old_timer) || 0) > 0,
              do: ref,
              else: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

          _ ->
            :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        end

      case ClientState.timer(state, hook) do
        {:ok, timer} -> Process.cancel_timer(timer)
        :error -> :ok
      end

      lease = make_ref()

      timer =
        Process.send_after(
          self(),
          {:expire_client, hook, client_id, lease},
          state.settings.client_timeout
        )

      {:ok,
       ClientState.put(state, hook, client_id, listen?, lease, timer,
         connected_at: connected_at,
         runtime_ref: runtime_ref
       )}
    end
  end

  defp ensure_http_poll_available(state, hook, client_id) do
    case ClientState.get(state, hook) do
      %{client_id: ^client_id, transport: :websocket} = client ->
        {:error, {:hook_already_connected, ClientState.retry_after_ms(state, client)}}

      _client ->
        ClientState.ensure_available(state, hook, client_id)
    end
  end

  defp client_id(opts) do
    case Keyword.get(opts, :client_id) do
      client_id when is_binary(client_id) and client_id != "" -> {:ok, client_id}
      _client_id -> {:error, :invalid_client_id}
    end
  end
end
