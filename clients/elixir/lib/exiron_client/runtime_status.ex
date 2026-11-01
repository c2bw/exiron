defmodule ExironClient.RuntimeStatus do
  @moduledoc false

  # Each poller owns one anonymous table. Publishing its reference in the process
  # dictionary allows reads during synchronous handlers and reconnect waits,
  # without a registry process or mailbox round trip. Only sanitized fields enter
  # the table; owner exit automatically removes it.
  @key {__MODULE__, :table}

  def attach(state) do
    table =
      case Process.get(@key) do
        nil ->
          table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

          :ets.insert(table, [
            {:meta,
             %{
               phase: :connecting,
               connected?: false,
               last_connected_at: nil,
               last_error: nil,
               retry_at: nil,
               drain_started_at: nil,
               drain_deadline: nil
             }},
            {:active, 0},
            {:completed, 0},
            {:quarantined, 0},
            {:timed_out, 0},
            {:batch, 0, nil}
          ])

          Process.put(@key, table)
          table

        table ->
          table
      end

    :ets.insert(
      table,
      {:handler_timeout, Keyword.get(state.handler_options, :handler_timeout_ms, 0)}
    )

    if store = state.handler_options[:quarantine],
      do: :ets.insert(table, {:quarantine_store, store})

    state
    |> Map.put(:runtime_status, table)
    |> Map.update!(:handler_options, &Keyword.put(&1, :runtime_status, table))
    |> ExironClient.RuntimeReporting.attach(table)
  end

  def read(pid) when is_pid(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_, table} <- List.keyfind(dictionary, @key, 0),
         [{:meta, meta}] <- :ets.lookup(table, :meta) do
      [{:active, active}] = :ets.lookup(table, :active)
      [{:completed, completed}] = :ets.lookup(table, :completed)
      [{:quarantined, quarantined}] = :ets.lookup(table, :quarantined)
      [{:timed_out, timed_out}] = :ets.lookup(table, :timed_out)
      [{:handler_timeout, timeout}] = :ets.lookup(table, :handler_timeout)

      overdue =
        :ets.match_object(table, {{:handler_deadline, :_}, :_, :_})
        |> Enum.flat_map(fn {_, deadline, flag} ->
          if :atomics.get(flag, 1) == 1 or (:atomics.get(flag, 1) == 0 and deadline <= now()),
            do: [max(now() - deadline, 0)],
            else: []
        end)

      quarantine =
        case :ets.lookup(table, :quarantine_store) do
          [{:quarantine_store, store}] ->
            case ExironClient.Quarantine.stats(store) do
              {:ok, stats} -> Map.put(stats, :available?, true)
              _ -> %{available?: false}
            end

          [] ->
            nil
        end

      [{:batch, size, started}] = :ets.lookup(table, :batch)

      meta =
        case :ets.lookup(table, :error) do
          [{:error, error}] -> %{meta | last_error: error}
          [] -> meta
        end

      phase =
        cond do
          meta.drain_started_at != nil -> :draining
          started != nil -> :handling
          true -> meta.phase
        end

      {:ok,
       meta
       |> Map.put(:phase, phase)
       |> Map.merge(%{
         handler_timeout_ms: timeout,
         overdue_handlers: length(overdue),
         oldest_overdue_ms: Enum.max(overdue, fn -> 0 end),
         batch_timed_out: timed_out,
         active_handlers: active,
         batch_size: size,
         batch_completed: completed,
         batch_quarantined: quarantined,
         quarantine: quarantine,
         batch_age_ms: if(started, do: max(now() - started, 0), else: 0),
         retry_in_ms: remaining(meta.retry_at),
         drain_remaining_ms: remaining(meta.drain_deadline)
       })
       |> Map.update!(:retry_at, &wall_time/1)
       |> Map.update!(:drain_deadline, &wall_time/1)}
    else
      _ -> {:error, :not_running}
    end
  rescue
    ArgumentError -> {:error, :not_running}
  end

  def phase(state, phase, delay \\ nil) do
    update(state, %{phase: phase, retry_at: if(delay, do: now() + delay)})
  end

  def connected(state) do
    update(state, %{
      connected?: true,
      last_connected_at: System.system_time(:millisecond),
      retry_at: nil
    })
  end

  def disconnected(state, reason) do
    update(state, %{connected?: false})
    error(state, reason)
  end

  def drain(state, deadline) do
    update(state, %{
      phase: :draining,
      drain_started_at: System.system_time(:millisecond),
      drain_deadline: deadline,
      retry_at: nil
    })
  end

  def error(state, reason) when reason in [nil, :normal, :shutdown], do: state

  def error(state, reason) do
    if table = Map.get(state, :runtime_status),
      do: :ets.insert(table, {:error, summarize(reason)})

    state
  end

  def handler_error(table) do
    if table,
      do:
        :ets.insert(
          table,
          {:error,
           %{kind: :handler_error, http_status: nil, at: System.system_time(:millisecond)}}
        )
  end

  def batch(table, messages, fun) do
    if table do
      :ets.insert(table, [
        {:batch, length(messages), if(messages != [], do: now())},
        {:completed, 0},
        {:quarantined, 0},
        {:timed_out, 0}
      ])
    end

    try do
      fun.()
    after
      if table, do: :ets.insert(table, {:batch, length(messages), nil})
    end
  end

  def deadline_started(table, token) do
    if table,
      do: :ets.insert(table, {{:handler_deadline, token.ref}, token.deadline_ms, token.flag})
  end

  def deadline_finished(table, token) do
    if table, do: :ets.delete(table, {:handler_deadline, token.ref})
  rescue
    ArgumentError -> :ok
  end

  def deadline_expired(table) do
    if table do
      :ets.update_counter(table, :timed_out, 1)

      :ets.insert(
        table,
        {:error,
         %{
           kind: :handler_deadline_exceeded,
           http_status: nil,
           at: System.system_time(:millisecond)
         }}
      )
    end
  rescue
    ArgumentError -> :ok
  end

  def quarantined(table) do
    if table, do: :ets.update_counter(table, :quarantined, 1)
  end

  def handler(table, fun) do
    if table, do: :ets.update_counter(table, :active, 1)

    try do
      result = fun.()
      if table && result == :ok, do: :ets.update_counter(table, :completed, 1)
      result
    after
      if table, do: :ets.update_counter(table, :active, -1)
    end
  end

  defp update(state, fields) do
    case Map.get(state, :runtime_status) do
      nil ->
        :ok

      table ->
        [{:meta, meta}] = :ets.lookup(table, :meta)
        :ets.insert(table, {:meta, Map.merge(meta, fields)})
    end

    state
  end

  defp summarize(reason) do
    {kind, status} =
      case reason do
        %ExironClient.Error{reason: kind, status: status} ->
          safe =
            if kind in [
                 :transport_error,
                 :hook_already_connected,
                 :client_lease_lost,
                 :invalid_response,
                 :http_error,
                 :draining,
                 :request_error,
                 :handler_deadline_exceeded
               ], do: kind, else: :client_error

          {safe, if(is_integer(status) and status in 100..599, do: status)}

        :drain_timeout ->
          {:deadline_exceeded, nil}

        _ ->
          {:error, nil}
      end

    %{kind: kind, http_status: status, at: System.system_time(:millisecond)}
  end

  defp remaining(nil), do: nil
  defp remaining(deadline), do: max(deadline - now(), 0)
  defp wall_time(nil), do: nil
  defp wall_time(deadline), do: System.system_time(:millisecond) + deadline - now()
  defp now, do: System.monotonic_time(:millisecond)
end
