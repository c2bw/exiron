defmodule ExironClient.RuntimeReporting do
  @moduledoc false
  @interval 5_000

  def options!(opts, client) do
    enabled = Keyword.get(opts, :runtime_reporting, :auto)

    unless enabled in [true, false, :auto],
      do: raise(ArgumentError, ":runtime_reporting must be true, false, or :auto")

    if enabled == true do
      unless is_binary(client.client_id) and byte_size(client.client_id) in 1..128,
        do: raise(ArgumentError, "runtime reporting requires a client ID of 1..128 bytes")

      [
        runtime_reporting_client: %{
          client
          | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)
        }
      ]
    else
      []
    end
  end

  def attach(state, table) do
    if client = state.handler_options[:runtime_reporting_client] do
      case :ets.lookup(table, :runtime_reporter) do
        [] ->
          :ets.insert(table, {:runtime_ref, nil})
          owner = self()

          pid =
            spawn(fn ->
              owner_ref = Process.monitor(owner)

              try do
                loop(owner, owner_ref, table, client, nil, 0)
              rescue
                _ -> :ok
              catch
                _, _ -> :ok
              end
            end)

          :ets.insert(table, {:runtime_reporter, pid})

        _ ->
          :ok
      end
    end

    state
  end

  def session(state, ref) do
    if state.handler_options[:runtime_reporting_client] do
      if is_binary(ref) and byte_size(ref) in 1..128 do
        set_ref(state, ref)
        :ok
      else
        {:error,
         ExironClient.Error.new(
           :invalid_response,
           "runtime reporting requires a session reference"
         )}
      end
    else
      :ok
    end
  end

  defp set_ref(state, ref) do
    if table = Map.get(state, :runtime_status) do
      case :ets.lookup(table, :runtime_ref) do
        [{:runtime_ref, ^ref}] ->
          :ok

        [{:runtime_ref, _}] ->
          :ets.insert(table, {:runtime_ref, ref})
          [{:runtime_reporter, pid}] = :ets.lookup(table, :runtime_reporter)
          send(pid, :runtime_report)

        [] ->
          :ok
      end
    end
  end

  defp loop(owner, monitor, table, client, last, sequence) do
    delay = if last, do: max(@interval - (now() - last), 0), else: @interval

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} -> :ok
      :runtime_report -> tick(owner, monitor, table, client, last, sequence)
    after
      delay -> tick(owner, monitor, table, client, last, sequence)
    end
  end

  defp tick(owner, monitor, table, client, last, sequence) do
    if last && now() - last < @interval do
      loop(owner, monitor, table, client, last, sequence)
    else
      attempted = now()

      sequence =
        case {:ets.lookup(table, :runtime_ref), ExironClient.RuntimeStatus.read(owner)} do
          {[{:runtime_ref, ref}], {:ok, status}} when is_binary(ref) ->
            sequence = sequence + 1
            active = clamp(status.active_handlers, 64)
            q = status.quarantine

            payload = %{
              client_id: client.client_id,
              runtime_ref: ref,
              sequence: sequence,
              phase: to_string(status.phase),
              active_handlers: active,
              overdue_handlers: clamp(status.overdue_handlers, active),
              quarantined_messages:
                clamp(if(q, do: Map.get(q, :count, 0), else: 0), 1_000_000_000),
              quarantine_bytes:
                clamp(if(q, do: Map.get(q, :bytes, 0), else: 0), 1_099_511_627_776),
              quarantine_enabled: not is_nil(q),
              quarantine_available: q != nil and Map.get(q, :available?, false)
            }

            send_report(owner, monitor, client, payload)
            sequence

          _ ->
            sequence
        end

      loop(owner, monitor, table, client, attempted, sequence)
    end
  end

  defp send_report(owner, monitor, client, payload) do
    task = Task.async(fn -> report(client, payload) end)
    ref = task.ref

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} ->
        Task.shutdown(task, :brutal_kill)
        exit(:normal)

      {^ref, _} ->
        Process.demonitor(ref, [:flush])

      {:DOWN, ^ref, :process, _, _} ->
        :ok
    after
      1000 -> Task.shutdown(task, :brutal_kill)
    end
  end

  defp report(client, payload) do
    opts = ExironClient.RequestOptions.control(client.req_options, json: payload)

    ExironClient.Request.request(client, :post, "/api/client-runtime", opts)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp clamp(value, limit), do: max(0, min(value, limit))
  defp now, do: System.monotonic_time(:millisecond)
end
