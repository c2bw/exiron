defmodule ExironClient.HTTPLease do
  @moduledoc false
  alias ExironClient.Lease

  def options!(opts, client, verify? \\ true) do
    case Keyword.get(opts, :http_lease_renewal, false) do
      false ->
        []

      true ->
        unless Keyword.get(opts, :transport, :websocket) == :http,
          do: raise(ArgumentError, "http_lease_renewal requires HTTP transport")

        control = %{
          client
          | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)
        }

        if verify?, do: ExironClient.FeatureNegotiation.require!(control, ["http_lease_renewal"])

        [http_lease_renewal: true]

      _ ->
        raise ArgumentError, "http_lease_renewal must be a boolean"
    end
  end

  def handle(delivery, state, fun) do
    if state.handler_options[:http_lease_renewal] && is_binary(delivery.delivery_id) &&
         delivery.messages != [] do
      with {:ok, ttl} <- renew(state.client, delivery.delivery_id, 1000),
           true <- state.interval_ms < ttl do
        with_lease(delivery, state, ttl, fun)
      else
        _ -> {:error, Lease.error()}
      end
    else
      fun.(state.handler_options)
    end
  end

  defp with_lease(delivery, state, ttl, fun) do
    table = :ets.new(__MODULE__, [:set, :public])
    token = %Lease{delivery_id: delivery.delivery_id, flag: :atomics.new(1, []), handlers: table}
    owner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)
        watch(state.client, token, ttl, state.interval_ms, owner, owner_ref)
      end)

    try do
      result = fun.(Keyword.put(state.handler_options, :lease_token, token))
      stop(pid, ref)

      cond do
        Lease.lost?(token) ->
          {:error, Lease.error()}

        result != :ok ->
          result

        true ->
          case renew(state.client, delivery.delivery_id, budget(ttl)) do
            {:ok, next_ttl} when next_ttl > state.interval_ms ->
              :ok

            _ ->
              Lease.mark_lost(token, owner)
              {:error, Lease.error()}
          end
      end
    after
      # stop/2 is idempotent through its separate monitor, including exceptions.
      cleanup_ref = Process.monitor(pid)
      stop(pid, cleanup_ref)
      Process.demonitor(ref, [:flush])
      :ets.delete(table)
      flush_signal(delivery.delivery_id)
    end
  end

  defp watch(client, token, ttl, interval, owner, owner_ref) do
    receive do
      :stop -> :ok
      {:DOWN, ^owner_ref, :process, ^owner, _} -> :ok
    after
      max(1, div(ttl, 3)) ->
        case renew(client, token.delivery_id, budget(ttl)) do
          {:ok, ttl} when ttl > interval -> watch(client, token, ttl, interval, owner, owner_ref)
          _ -> Lease.mark_lost(token, owner)
        end
    end
  rescue
    # owner/table disappeared during a control request
    ArgumentError -> :ok
  end

  defp renew(client, batch, timeout) do
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        try do
          opts = [
            receive_timeout: timeout,
            finch: [pool_timeout: timeout, receive_timeout: timeout]
          ]

          ExironClient.renew_http_lease(client, batch, opts)
        rescue
          _ -> {:error, Lease.error()}
        catch
          _, _ -> {:error, Lease.error()}
        end
      end)

    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, %{"ok" => true, "lease_timeout_ms" => ttl}}}
      when is_integer(ttl) and ttl > 0 ->
        if System.monotonic_time(:millisecond) - started < budget(ttl),
          do: {:ok, ttl},
          else: {:error, Lease.error()}

      _ ->
        {:error, Lease.error()}
    end
  end

  defp budget(ttl), do: max(1, min(1000, div(ttl, 4)))

  defp stop(pid, ref) do
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1200 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end
    end
  end

  defp flush_signal(batch) do
    receive do
      {:exiron_client_lease_lost, ^batch} -> flush_signal(batch)
    after
      0 -> :ok
    end
  end
end
