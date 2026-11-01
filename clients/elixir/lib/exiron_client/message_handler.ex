defmodule ExironClient.MessageHandler do
  @moduledoc false

  def handle(messages, handler, opts \\ []) do
    opts =
      if Keyword.get(opts, :handler_timeout_ms, 0) > 0,
        do: Keyword.put(opts, :deadline_batch, :atomics.new(1, [])),
        else: opts

    ExironClient.RuntimeStatus.batch(opts[:runtime_status], messages, fn ->
      handle_batch(messages, handler, opts)
    end)
  end

  defp handle_batch(messages, handler, opts) do
    concurrency = Keyword.get(opts, :concurrency, 1)

    if concurrency == 1 do
      Enum.reduce_while(messages, :ok, fn message, :ok ->
        case handle_message(message, handler, opts) do
          {:error, reason} -> {:halt, {:error, reason}}
          _success -> {:cont, :ok}
        end
      end)
    else
      concurrent(messages, handler, opts, concurrency)
    end
  end

  defp handle_message(message, handler, opts) do
    ExironClient.RuntimeStatus.handler(opts[:runtime_status], fn ->
      ExironClient.HandlerDeadline.with_budget(opts, fn ->
        ExironClient.Lease.with_handler(opts[:lease_token], fn ->
          ExironClient.Cancellation.with_message(message, opts, fn ->
            attempt(message, handler, opts, 1)
          end)
        end)
      end)
    end)
  end

  defp concurrent(messages, handler, opts, concurrency) do
    failed = :atomics.new(1, [])

    lanes =
      if opts[:order_by_chat],
        do: ExironClient.ConversationOrder.lanes(messages),
        else: Stream.map(messages, &[&1])

    lanes
    |> Stream.take_while(fn _ ->
      :atomics.get(failed, 1) == 0 and not ExironClient.HandlerDeadline.batch_expired?(opts)
    end)
    |> Task.async_stream(
      fn lane ->
        Enum.reduce_while(lane, :ok, fn message, :ok ->
          if :atomics.get(failed, 1) == 0 and
               not ExironClient.HandlerDeadline.batch_expired?(opts) do
            case handle_message(message, handler, opts) do
              {:error, _} = error ->
                :atomics.put(failed, 1, 1)
                {:halt, error}

              _ ->
                {:cont, :ok}
            end
          else
            {:halt, :ok}
          end
        end)
      end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(:ok, fn
      {:ok, {:error, reason}}, :ok -> {:error, reason}
      _result, accumulated -> accumulated
    end)
    |> then(fn result ->
      if result == :ok and ExironClient.HandlerDeadline.batch_expired?(opts),
        do: {:error, ExironClient.HandlerDeadline.error()},
        else: result
    end)
  end

  defp attempt(message, handler, opts, number) do
    max_attempts = Keyword.get(opts, :max_attempts, 1)

    cond do
      ExironClient.Lease.lost?() -> {:error, ExironClient.Lease.error()}
      ExironClient.HandlerDeadline.expired?() -> {:error, ExironClient.HandlerDeadline.error()}
      ExironClient.Cancellation.cancelled?() -> :ok
      true -> do_attempt(message, handler, opts, number, max_attempts)
    end
  end

  defp do_attempt(message, handler, opts, number, max_attempts) do
    result = invoke(handler, message)

    result =
      cond do
        ExironClient.Lease.lost?() -> {:error, ExironClient.Lease.error()}
        ExironClient.HandlerDeadline.expired?() -> {:error, ExironClient.HandlerDeadline.error()}
        ExironClient.Cancellation.cancelled?() -> :ok
        true -> result
      end

    case result do
      {:error, %ExironClient.Error{reason: :handler_deadline_exceeded}} ->
        {:error, ExironClient.HandlerDeadline.error()}

      {:error, %ExironClient.Error{reason: :client_lease_lost}} ->
        {:error, ExironClient.Lease.error()}

      {:error, %ExironClient.Error{reason: :request_cancelled}} ->
        :ok

      {:error, reason} ->
        ExironClient.RuntimeStatus.handler_error(opts[:runtime_status])
        retry? = number < max_attempts

        ExironClient.HandlerReporting.report(
          message,
          opts,
          number,
          max_attempts,
          if(retry?, do: "retrying", else: "exhausted"),
          reason
        )

        callback = Keyword.get(opts, :on_error, fn _failure -> :ok end)

        callback.(%{
          request_id: message.req_id,
          attempt: number,
          max_attempts: max_attempts,
          will_retry?: retry?,
          reason: reason
        })

        if retry? do
          wait = Keyword.get(opts, :wait, &ExironClient.HandlerDeadline.wait/1)
          wait.(Keyword.get(opts, :retry_delay_ms, 250))
          attempt(message, handler, opts, number + 1)
        else
          if opts[:failure_policy] == :quarantine,
            do: ExironClient.Quarantine.exhausted(message, opts, number, reason),
            else: {:error, reason}
        end

      _ ->
        if number > 1 and not ExironClient.Cancellation.cancelled?(),
          do:
            ExironClient.HandlerReporting.report(message, opts, number, max_attempts, "recovered")

        :ok
    end
  end

  defp invoke(handler, message) do
    handler.(message)
  rescue
    error -> {:error, error}
  end
end
