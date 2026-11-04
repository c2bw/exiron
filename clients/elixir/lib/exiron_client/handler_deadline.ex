defmodule ExironClient.HandlerDeadline do
  @moduledoc """
  Cooperative per-message time budgets for managed handlers. A budget spans
  setup, all attempts and retry waits in the occupied slot. Expiry signals the
  handler but never kills it, releases its slot, acknowledges or quarantines it.
  """
  @key :exiron_handler_deadline
  @derive {Inspect, only: [:deadline_ms]}
  defstruct [:ref, :deadline_ms, :flag, :batch, :table]

  def current, do: Process.get(@key)
  def expired?(token \\ current())

  def expired?(%__MODULE__{} = token) do
    case :atomics.get(token.flag, 1) do
      1 ->
        true

      2 ->
        false

      0 ->
        if now() >= token.deadline_ms do
          expire(token)
          :atomics.get(token.flag, 1) == 1
        else
          false
        end
    end
  end

  def expired?(_), do: false

  def remaining_ms(token \\ current())

  def remaining_ms(%__MODULE__{} = token) do
    if :atomics.get(token.flag, 1) == 2, do: nil, else: max(token.deadline_ms - now(), 0)
  end

  def remaining_ms(_), do: nil

  @doc "A local control error; it is never eligible for automatic retry or quarantine."
  def error,
    do: ExironClient.Error.new(:handler_deadline_exceeded, "handler execution deadline exceeded")

  def check, do: if(expired?(), do: {:error, error()}, else: :ok)

  @doc false
  def batch_expired?(opts),
    do: opts[:deadline_batch] != nil and :atomics.get(opts[:deadline_batch], 1) == 1

  @doc false
  def with_budget(opts, fun) do
    cond do
      batch_expired?(opts) -> {:error, error()}
      Keyword.get(opts, :handler_timeout_ms, 0) == 0 -> fun.()
      true -> run(opts, fun)
    end
  end

  defp run(opts, fun) do
    token = %__MODULE__{
      ref: make_ref(),
      deadline_ms: now() + opts[:handler_timeout_ms],
      flag: :atomics.new(1, []),
      batch: opts[:deadline_batch],
      table: opts[:runtime_status]
    }

    previous = Process.put(@key, token)
    ExironClient.RuntimeStatus.deadline_started(token.table, token)
    owner = self()

    watcher =
      spawn(fn ->
        owner_ref = Process.monitor(owner)

        receive do
          :stop -> :ok
          {:DOWN, ^owner_ref, :process, ^owner, _} -> :ok
        after
          max(token.deadline_ms - now(), 0) ->
            expire(token)
            send(owner, {:exiron_handler_deadline, token.ref})
        end
      end)

    try do
      result = fun.()
      stop(watcher)
      with :ok <- check(), do: result
    after
      stop(watcher)
      :atomics.compare_exchange(token.flag, 1, 0, 2)
      ExironClient.RuntimeStatus.deadline_finished(token.table, token)
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
      flush(token.ref)
    end
  end

  defp expire(token) do
    if :atomics.compare_exchange(token.flag, 1, 0, 1) == :ok do
      if token.batch, do: :atomics.put(token.batch, 1, 1)
      ExironClient.RuntimeStatus.deadline_expired(token.table)
    end
  end

  @doc "Wait up to the requested duration, waking for local deadline or server cancellation."
  def wait(milliseconds) do
    case current() do
      nil ->
        ExironClient.Cancellation.wait(milliseconds)

      token ->
        duration = min(milliseconds, remaining_ms(token) || 0)
        ref = token.ref
        cancellation = ExironClient.Cancellation.current()
        id = if cancellation, do: cancellation.req_id

        unless expired?(token) or ExironClient.Cancellation.cancelled?() do
          receive do
            {:exiron_handler_deadline, ^ref} -> :ok
            {:exiron_request_cancelled, ^id, _} when not is_nil(id) -> :ok
          after
            duration -> :ok
          end
        end

        check()
    end
  end

  @doc false
  def retry_wait(backoff, delay_ms) do
    remaining = remaining_ms()

    if is_integer(remaining) and delay_ms > remaining do
      case wait(remaining) do
        {:error, _} = error ->
          error

        :ok ->
          if ExironClient.Cancellation.cancelled?(),
            do:
              {:error, ExironClient.Error.new(:request_cancelled, "request cancelled by server")},
            else: {:error, error()}
      end
    else
      result = ExironClient.ReconnectPolicy.sleep(backoff, delay_ms)
      with :ok <- check(), do: result
    end
  end

  @doc false
  def request_options(opts) do
    with :ok <- check() do
      case remaining_ms() do
        nil ->
          {:ok, opts}

        remaining ->
          budget = max(remaining, 1)
          opts = cap(opts, :receive_timeout, budget)
          finch = opts |> Keyword.get(:finch, []) |> cap(:pool_timeout, budget)

          finch =
            if Keyword.has_key?(finch, :receive_timeout),
              do: cap(finch, :receive_timeout, budget),
              else: finch

          opts = Keyword.put(opts, :finch, finch)

          # Connection settings identify Req's reusable Finch pools. A shrinking
          # per-request timeout here would create a pool for each budget value.
          {:ok, opts}
      end
    end
  end

  defp cap(opts, key, budget) do
    Keyword.update(opts, key, budget, fn
      value when is_integer(value) -> min(value, budget)
      :infinity -> budget
      value -> value
    end)
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1000 ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end
  end

  defp flush(ref) do
    receive do
      {:exiron_handler_deadline, ^ref} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
