defmodule Exiron.Hub.BotLookupTasks do
  @moduledoc false

  use GenServer

  alias Exiron.Telemetry

  @default_max_concurrency 8
  @default_max_queue 256
  @default_retry_delay_ms 5_000

  @type work :: %{
          owner: pid(),
          item: term(),
          resolver: (term() -> term()),
          message: (term(), term() -> term())
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @spec start(Enumerable.t(), (term() -> term()), (term(), term() -> term()), keyword()) :: :ok
  def start(items, resolver, message, opts \\ []) do
    owner = self()
    dispatcher = Keyword.get(opts, :dispatcher, __MODULE__)

    case enqueue(dispatcher, owner, items, resolver, message) do
      :ok ->
        :ok

      {:error, :unavailable} ->
        items
        |> Enum.each(fn item ->
          emit_result(owner, item, message, {:error, :lookup_unavailable}, 0, :unavailable)
        end)

        :ok
    end
  end

  @spec dispatch_options(keyword()) :: keyword()
  def dispatch_options(opts) do
    [dispatcher: Keyword.get(opts, :bot_lookup_dispatcher, __MODULE__)]
  end

  # Lookup tasks may finish after a configuration reload. Only their originating
  # generation may update the active Telegram configuration.
  def current_generation?(state, generation),
    do: state.lookups.generation == generation

  def schedule_retry(message, opts) do
    Process.send_after(self(), message, retry_delay(opts))
  end

  def retry_delay(opts),
    do: opts |> Keyword.get(:bot_lookup_retry_delay_ms, @default_retry_delay_ms) |> max(1)

  def retryable_result?({:error, %ExGram.Error{code: code}})
      when code in [400, 401, 403, 404],
      do: false

  def retryable_result?({:error, _reason}), do: true
  def retryable_result?(_result), do: false

  @impl true
  def init(opts) do
    {:ok,
     %{
       queue: :queue.new(),
       active: %{},
       task_supervisor: Keyword.get(opts, :task_supervisor, Exiron.Hub.LookupSupervisor),
       max_concurrency: positive_option(opts, :max_concurrency, @default_max_concurrency),
       max_queue: positive_option(opts, :max_queue, @default_max_queue)
     }}
  end

  @impl true
  def handle_call({:enqueue, owner, items, resolver, message}, _from, state) do
    {accepted, rejected} = split_available(items, state)

    Enum.each(rejected, fn item ->
      emit_result(owner, item, message, {:error, :lookup_queue_full}, 0, :queue_full)
    end)

    queue =
      Enum.reduce(accepted, state.queue, fn item, queue ->
        :queue.in(%{owner: owner, item: item, resolver: resolver, message: message}, queue)
      end)

    {:reply, :ok, dispatch(%{state | queue: queue})}
  end

  @impl true
  def handle_info({:lookup_result, pid, result}, state) do
    case Map.pop(state.active, pid) do
      {nil, _active} ->
        {:noreply, state}

      {%{owner: owner, item: item, message: message, started_at: started_at}, active} ->
        Process.demonitor(Map.fetch!(state.active, pid).monitor, [:flush])
        duration = duration_since(started_at)
        emit_result(owner, item, message, result, duration, outcome(result))

        {:noreply, dispatch(%{state | active: active})}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case Map.get(state.active, pid) do
      %{monitor: ^monitor} = work ->
        active = Map.delete(state.active, pid)

        if reason != :normal do
          emit_result(
            work.owner,
            work.item,
            work.message,
            {:error, {:exit, reason}},
            duration_since(work.started_at),
            :task_exit
          )
        end

        {:noreply, dispatch(%{state | active: active})}

      _work ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) do
    Exiron.OTPStatus.redact(status, &status_state/1)
  end

  defp enqueue(dispatcher, owner, items, resolver, message) do
    GenServer.call(dispatcher, {:enqueue, owner, items, resolver, message}, :infinity)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp dispatch(state) do
    if map_size(state.active) < state.max_concurrency do
      case :queue.out(state.queue) do
        {{:value, work}, queue} ->
          state = %{state | queue: queue}

          case start_task(state, work) do
            {:ok, pid, work} ->
              dispatch(%{state | active: Map.put(state.active, pid, work)})

            {:error, _reason} ->
              emit_result(
                work.owner,
                work.item,
                work.message,
                {:error, :lookup_unavailable},
                0,
                :unavailable
              )

              dispatch(state)
          end

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp start_task(state, work) do
    dispatcher = self()
    started_at = System.monotonic_time()

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           result = safe_result(work.resolver, work.item)
           send(dispatcher, {:lookup_result, self(), result})
         end) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        {:ok, pid, Map.merge(work, %{monitor: monitor, started_at: started_at})}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp split_available(items, state) do
    available = max(state.max_queue - map_size(state.active) - :queue.len(state.queue), 0)
    Enum.split(items, available)
  end

  defp safe_result(resolver, item) do
    resolver.(item)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp emit_result(owner, item, message, result, duration, outcome) do
    Telemetry.lookup(duration, outcome)

    case safe_message(message, item, result) do
      {:ok, value} -> send(owner, value)
      :error -> :ok
    end
  end

  defp safe_message(message, item, result) do
    {:ok, message.(item, result)}
  catch
    _kind, _reason -> :error
  end

  defp duration_since(started_at), do: max(System.monotonic_time() - started_at, 0)

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:error, _reason}), do: :error
  defp outcome(_result), do: :error

  defp positive_option(opts, key, default) do
    opts |> Keyword.get(key, default) |> max(1)
  end

  defp status_state(state) when is_map(state) do
    %{
      queued: queue_length(Map.get(state, :queue, :queue.new())),
      active: state |> Map.get(:active, %{}) |> map_size(),
      max_concurrency: Map.get(state, :max_concurrency),
      max_queue: Map.get(state, :max_queue)
    }
  end

  defp status_state(_state), do: :redacted

  defp queue_length(queue) do
    :queue.len(queue)
  catch
    _kind, _reason -> 0
  end
end
