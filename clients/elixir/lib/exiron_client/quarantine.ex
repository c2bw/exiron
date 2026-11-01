defmodule ExironClient.Quarantine do
  @moduledoc """
  Bounded in-memory storage for opted-in exhausted handler failures.

  Supervise this store separately from pollers and reuse its PID across poller
  restarts. Defaults are 100 messages and 8 MiB of encoded message bytes. No
  eviction or automatic recovery occurs; store restart loses retained messages.
  Use a separate store per logical hook/application consumer.
  """
  use GenServer
  @key {__MODULE__, :table}

  def start_link(opts) do
    count = Keyword.get(opts, :max_messages, 100)
    bytes = Keyword.get(opts, :max_bytes, 8 * 1024 * 1024)

    unless is_integer(count) and count > 0 and is_integer(bytes) and bytes > 0,
      do: raise(ArgumentError, "quarantine limits must be positive integers")

    GenServer.start_link(__MODULE__, {count, bytes}, Keyword.take(opts, [:name]))
  end

  @doc "Read counts and limits locally without a mailbox round trip."
  def stats(pid) when is_pid(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_, table} <- List.keyfind(dictionary, @key, 0),
         [{:stats, stats}] <- :ets.lookup(table, :stats) do
      {:ok, stats}
    else
      _ -> {:error, :quarantine_unavailable}
    end
  rescue
    ArgumentError -> {:error, :quarantine_unavailable}
  end

  def stats(_), do: {:error, :quarantine_unavailable}

  @doc "List bounded metadata, including recovery IDs; payloads and errors are excluded."
  def entries(pid), do: call(pid, :entries)

  @doc """
  Invoke an explicit one-argument recovery callback in the calling process.
  Only :ok removes the entry. Errors, exceptions and caller death retain it.
  Concurrent recovery of the same entry is rejected. Callback execution adds no
  managed retries, leases, server acknowledgements or cancellation watchers.
  """
  def recover(pid, id, callback) when is_function(callback, 1) do
    ref = make_ref()

    case call(pid, {:claim, id, self(), ref}) do
      {:ok, encoded} ->
        result =
          try do
            case callback.(:erlang.binary_to_term(encoded, [:safe])) do
              :ok -> :ok
              {:error, _} = error -> error
              _ -> {:error, :invalid_recovery_result}
            end
          rescue
            error -> {:error, error}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case call(pid, {:finish, id, ref, result == :ok}) do
          :ok -> result
          error -> error
        end

      error ->
        # A timed-out claim may still be queued; same-sender ordering ensures
        # abandonment releases it even if the call's late response was lost.
        send(pid, {:abandon, id, ref})
        error
    end
  end

  @doc false
  def put(pid, message, attempts) do
    with {:ok, stats} <- stats(pid) do
      if :erlang.external_size(message) > stats.max_bytes do
        {:error, :quarantine_full}
      else
        encoded = :erlang.term_to_binary(message)
        call(pid, {:put, encoded, message.req_id, attempts})
      end
    end
  end

  @doc false
  def exhausted(message, opts, attempts, reason) do
    cond do
      ExironClient.Lease.lost?() ->
        {:error, ExironClient.Lease.error()}

      ExironClient.HandlerDeadline.expired?() ->
        {:error, ExironClient.HandlerDeadline.error()}

      ExironClient.Cancellation.cancelled?() ->
        :ok

      true ->
        case put(opts[:quarantine], message, attempts) do
          {:ok, entry} ->
            ExironClient.RuntimeStatus.quarantined(opts[:runtime_status])
            callback = Keyword.get(opts, :on_quarantined, fn _ -> :ok end)
            callback.(entry)
            if ExironClient.Lease.lost?(), do: {:error, ExironClient.Lease.error()}, else: :ok

          {:error, failure} ->
            {:error, {:quarantine_failed, failure, reason}}
        end
    end
  end

  @impl true
  def init({count, bytes}) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    Process.put(@key, table)

    state = %{
      table: table,
      max_messages: count,
      max_bytes: bytes,
      bytes: 0,
      next: 0,
      entries: %{},
      claims: %{}
    }

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:entries, _, state) do
    entries = state.entries |> Map.values() |> Enum.map(& &1.meta) |> Enum.sort_by(& &1.id)
    {:reply, {:ok, entries}, state}
  end

  def handle_call({:put, encoded, request, attempts}, _, state) do
    size = byte_size(encoded)

    if map_size(state.entries) >= state.max_messages or size > state.max_bytes - state.bytes do
      {:reply, {:error, :quarantine_full}, state}
    else
      id = state.next + 1

      request = if is_binary(request), do: :binary.copy(request), else: nil

      meta = %{
        id: id,
        request_id: request,
        attempts: attempts,
        bytes: size,
        created_at: System.system_time(:millisecond),
        recovering?: false
      }

      item = %{meta: meta, encoded: encoded, claim: nil}

      state = %{
        state
        | next: id,
          bytes: state.bytes + size,
          entries: Map.put(state.entries, id, item)
      }

      {:reply, {:ok, meta}, publish(state)}
    end
  end

  def handle_call({:claim, id, owner, ref}, _, state) do
    case Map.get(state.entries, id) do
      nil ->
        {:reply, {:error, :quarantine_not_found}, state}

      %{claim: nil} = item ->
        monitor = Process.monitor(owner)
        item = %{item | claim: {ref, monitor}, meta: %{item.meta | recovering?: true}}

        state = %{
          state
          | entries: Map.put(state.entries, id, item),
            claims: Map.put(state.claims, monitor, {id, ref})
        }

        {:reply, {:ok, item.encoded}, publish(state)}

      _ ->
        {:reply, {:error, :quarantine_busy}, state}
    end
  end

  def handle_call({:finish, id, ref, success}, _, state) do
    {:reply, :ok, release(state, id, ref, success)}
  end

  @impl true
  def handle_info({:abandon, id, ref}, state), do: {:noreply, release(state, id, ref, false)}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Map.get(state.claims, monitor) do
      {id, ref} -> {:noreply, release(state, id, ref, false)}
      nil -> {:noreply, state}
    end
  end

  @impl true
  def format_status(status) do
    ExironClient.OTPStatus.redact(status, fn state -> stats_map(state) end)
  end

  defp release(state, id, ref, success) do
    case Map.get(state.entries, id) do
      %{claim: {^ref, monitor}} = item ->
        Process.demonitor(monitor, [:flush])

        entries =
          if success,
            do: Map.delete(state.entries, id),
            else:
              Map.put(state.entries, id, %{
                item
                | claim: nil,
                  meta: %{item.meta | recovering?: false}
              })

        publish(%{
          state
          | entries: entries,
            claims: Map.delete(state.claims, monitor),
            bytes: if(success, do: state.bytes - item.meta.bytes, else: state.bytes)
        })

      _ ->
        state
    end
  end

  defp publish(state) do
    :ets.insert(state.table, {:stats, stats_map(state)})
    state
  end

  defp stats_map(state),
    do: %{
      count: map_size(state.entries),
      bytes: state.bytes,
      max_messages: state.max_messages,
      max_bytes: state.max_bytes,
      recovering: map_size(state.claims)
    }

  defp call(pid, request) do
    GenServer.call(pid, request, 1000)
  catch
    :exit, _ -> {:error, :quarantine_unavailable}
  end
end
