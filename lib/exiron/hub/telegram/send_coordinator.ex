defmodule Exiron.Hub.Telegram.SendCoordinator do
  @moduledoc false
  use GenServer
  alias Exiron.Hub.Telegram.RejectionCache

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # Payloads and credentials stay in the caller. The coordinator stores only a
  # bot digest, caller references and cooldown deadlines, bounded by send tasks.
  def run(token, fun, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    key = :crypto.hash(:sha256, token)

    attempt(
      server,
      key,
      fun,
      0,
      Keyword.get(opts, :max_retries, 2),
      Keyword.take(opts, [:chat_id, :bot_name])
    )
  end

  def retry_delay(%ExGram.Error{code: 429, metadata: metadata}) when is_map(metadata) do
    parameters = Map.get(metadata, :parameters, Map.get(metadata, "parameters", %{}))

    seconds =
      if is_map(parameters),
        do: Map.get(parameters, :retry_after, Map.get(parameters, "retry_after"))

    if is_integer(seconds) and seconds > 0, do: seconds * 1000, else: nil
  end

  def retry_delay(_), do: nil

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :suppression_snapshot, 500)
  catch
    :exit, _ ->
      %{
        available: false,
        active: 0,
        suppressed_attempts: 0,
        rejections: 0,
        probes: 0,
        recoveries: 0,
        last_recovery: nil,
        records: []
      }
  end

  def clear_suppression(server \\ __MODULE__), do: GenServer.call(server, :clear_suppression)

  defp attempt(server, key, fun, number, max_retries, context) do
    :ok = GenServer.call(server, {:acquire, key}, :infinity)

    case GenServer.call(server, {:check_suppression, key, context[:chat_id]}) do
      {:blocked, code} ->
        :ok = GenServer.call(server, {:release, key, 0})

        {:error,
         %ExGram.Error{
           code: code,
           message: "Telegram bot temporarily suppressed after a definitive rejection",
           metadata: %{exiron_suppressed: true}
         }}

      :ok ->
        perform_attempt(server, key, fun, number, max_retries, context)
    end
  end

  defp perform_attempt(server, key, fun, number, max_retries, context) do
    trace(:telegram_attempt, nil)

    result =
      try do
        fun.()
      catch
        kind, reason ->
          GenServer.call(server, {:release_result, key, 0, context, {:error, :uncertain}})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    delay =
      case result do
        {:error, error} -> retry_delay(error)
        _ -> nil
      end

    :ok =
      GenServer.call(
        server,
        {:release_result, key, delay || 0, context, rejection_outcome(result)}
      )

    if delay do
      trace(:telegram_rate_limited, delay)

      if number < max_retries,
        do: attempt(server, key, fun, number + 1, max_retries, context),
        else: result
    else
      result
    end
  end

  # The coordinator needs only a classification, never a receipt, payload or
  # Telegram error body. Keep those terms in the caller.
  defp rejection_outcome({:error, %ExGram.Error{code: code}}) when code in [401, 403],
    do: {:error, %ExGram.Error{code: code}}

  defp rejection_outcome(:ok), do: :ok
  defp rejection_outcome({:ok, _}), do: :ok
  defp rejection_outcome(_), do: {:error, :uncertain}

  defp trace(kind, delay) do
    case Process.get(:exiron_trace_send) do
      {owner, ref, id} when is_binary(id) -> send(owner, {:trace_send, ref, id, kind, delay})
      _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    cache = %RejectionCache{
      cooldown_ms: Keyword.get(opts, :rejection_cooldown_ms, 60_000),
      limit: Keyword.get(opts, :rejection_limit, 1000)
    }

    {:ok,
     %{
       bots: %{},
       monitors: %{},
       rejection_cache: cache,
       clock: Keyword.get(opts, :clock, &now/0),
       notify?: Keyword.get(opts, :name, __MODULE__) == __MODULE__
     }}
  end

  def handle_call(:suppression_snapshot, _from, state),
    do: {:reply, RejectionCache.snapshot(state.rejection_cache, state.clock.()), state}

  def handle_call(:clear_suppression, _from, state) do
    cache = %{
      state.rejection_cache
      | entries: %{},
        suppressed: 0,
        rejections: 0,
        probes: 0,
        recoveries: 0,
        last_recovery: nil
    }

    state = put_cache(state, cache)
    {:reply, :ok, state}
  end

  def handle_call({:check_suppression, key, chat}, {pid, _}, state) do
    case Map.get(state.bots, key) do
      %{owner: {^pid, _}} ->
        case RejectionCache.check(state.rejection_cache, key, chat, state.clock.()) do
          {:ok, cache} -> {:reply, :ok, put_cache(state, cache)}
          {:blocked, code, cache} -> {:reply, {:blocked, code}, put_cache(state, cache)}
        end

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:release_result, key, delay, context, result}, {pid, _} = from, state) do
    case Map.get(state.bots, key) do
      %{owner: {^pid, _}} ->
        cache =
          RejectionCache.record(
            state.rejection_cache,
            key,
            context[:chat_id],
            context[:bot_name],
            result,
            state.clock.()
          )

        handle_call({:release, key, delay}, from, put_cache(state, cache))

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_call({:acquire, key}, {pid, _} = from, state) do
    monitor = Process.monitor(pid)

    entry =
      Map.get(state.bots, key, %{owner: nil, queue: :queue.new(), ready_at: now(), timer: nil})

    entry = %{entry | queue: :queue.in({from, monitor}, entry.queue)}

    state = %{
      state
      | bots: Map.put(state.bots, key, entry),
        monitors: Map.put(state.monitors, monitor, key)
    }

    {:noreply, dispatch(state, key)}
  end

  def handle_call({:release, key, delay}, {pid, _}, state) do
    case Map.get(state.bots, key) do
      %{owner: {^pid, monitor}} = entry ->
        Process.demonitor(monitor, [:flush])
        entry = %{entry | owner: nil, ready_at: now() + delay}

        state = %{
          state
          | bots: Map.put(state.bots, key, entry),
            monitors: Map.delete(state.monitors, monitor)
        }

        {:reply, :ok, dispatch(state, key)}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_info({:ready, key, generation}, state) do
    case Map.get(state.bots, key) do
      %{timer: {^generation, _}} = entry ->
        state = put_in(state.bots[key], %{entry | timer: nil})
        {:noreply, dispatch(state, key)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} ->
        {:noreply, state}

      {key, monitors} ->
        entry = Map.fetch!(state.bots, key)

        owner =
          case entry.owner do
            {_, ^monitor} -> nil
            other -> other
          end

        queue =
          entry.queue
          |> :queue.to_list()
          |> Enum.reject(fn {_, ref} -> ref == monitor end)
          |> :queue.from_list()

        state = %{
          state
          | monitors: monitors,
            bots: Map.put(state.bots, key, %{entry | owner: owner, queue: queue})
        }

        {:noreply, dispatch(state, key)}
    end
  end

  @impl true
  def format_status(status),
    do:
      Exiron.OTPStatus.redact(status, fn state ->
        %{
          bots: map_size(state.bots),
          callers: map_size(state.monitors),
          rejection_records: map_size(state.rejection_cache.entries)
        }
      end)

  defp put_cache(state, cache) do
    if cache != state.rejection_cache and state.notify? do
      if hub = Process.whereis(Exiron.Hub), do: send(hub, :telegram_suppression_changed)
    end

    %{state | rejection_cache: cache}
  end

  defp dispatch(state, key) do
    entry = Map.fetch!(state.bots, key)

    cond do
      entry.owner != nil ->
        state

      entry.ready_at > now() ->
        if entry.timer do
          state
        else
          generation = make_ref()

          timer =
            Process.send_after(
              self(),
              {:ready, key, generation},
              min(entry.ready_at - now(), 60_000) |> max(0)
            )

          put_in(state.bots[key], %{entry | timer: {generation, timer}})
        end

      true ->
        case :queue.out(entry.queue) do
          {:empty, _} ->
            %{state | bots: Map.delete(state.bots, key)}

          {{:value, {{pid, _} = from, monitor}}, queue} ->
            GenServer.reply(from, :ok)
            put_in(state.bots[key], %{entry | owner: {pid, monitor}, queue: queue})
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
