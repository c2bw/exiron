defmodule ExironClient.Cancellation do
  @moduledoc "Cooperative cancellation for opt-in managed handlers. Signals never kill the handler."
  alias ExironClient.Request
  @key :exiron_request_cancellation
  @derive {Inspect, only: [:req_id]}
  defstruct [:req_id, :flag]

  @doc "The token for this managed handler, or nil when cooperative cancellation is disabled."
  def current, do: Process.get(@key)
  def cancelled?(token \\ current())
  def cancelled?(%__MODULE__{flag: flag}), do: :atomics.get(flag, 1) != 0
  def cancelled?(_), do: false
  def reason(token \\ current())

  def reason(%__MODULE__{flag: flag}) do
    case :atomics.get(flag, 1) do
      1 -> :cancelled
      2 -> :expired
      _ -> nil
    end
  end

  def reason(_), do: nil

  @doc false
  def options!(opts, client, verify? \\ true) do
    case Keyword.get(opts, :cooperative_cancellation, false) do
      false ->
        []

      true ->
        interval = Keyword.get(opts, :cancellation_interval_ms, 1000)

        unless is_integer(interval) and interval >= 100,
          do: raise(ArgumentError, "cancellation_interval_ms must be at least 100")

        callback = Keyword.get(opts, :on_request_cancelled, fn _event -> :ok end)

        unless is_function(callback, 1),
          do: raise(ArgumentError, "on_request_cancelled must be a one-argument function")

        control = %{
          client
          | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)
        }

        if verify?,
          do: ExironClient.FeatureNegotiation.require!(control, ["cooperative_cancellation"])

        [
          cancellation_client: control,
          cancellation_interval_ms: interval,
          on_request_cancelled: callback
        ]

      _ ->
        raise ArgumentError, "cooperative_cancellation must be a boolean"
    end
  end

  @doc false
  def with_message(message, opts, fun) do
    client = Keyword.get(opts, :cancellation_client)

    if client && is_binary(message.req_id) && message.req_id != "" && message.msgtype != "listen" do
      token = %__MODULE__{req_id: message.req_id, flag: :atomics.new(1, [])}
      previous = Process.put(@key, token)
      initial = state(client, message.req_id)
      owner = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          owner_ref = Process.monitor(owner)
          watch(client, token, owner, owner_ref, initial, opts)
        end)

      try do
        # The initial check also skips cancellation that arrived before a queued
        # sibling's handler began; no handler or retry is needed for that work.
        if initial in ["cancelled", "expired"] do
          notify(token, owner, initial, opts)
          :ok
        else
          result = fun.()
          if cancelled?(token), do: :ok, else: result
        end
      after
        send(pid, :stop)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          1100 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^monitor, :process, ^pid, _} -> :ok
            end
        end

        if previous, do: Process.put(@key, previous), else: Process.delete(@key)
        flush_signal(message.req_id)
      end
    else
      fun.()
    end
  end

  @doc false
  def wait(milliseconds) do
    case current() do
      %__MODULE__{req_id: id} = token ->
        unless cancelled?(token) do
          receive do
            {:exiron_request_cancelled, ^id, _reason} -> :ok
          after
            milliseconds -> :ok
          end
        end

      _ ->
        Process.sleep(milliseconds)
    end
  end

  defp watch(_client, _token, _owner, _ref, status, _opts)
       when status in ["completed", "closed", "cancelled", "expired"], do: :ok

  defp watch(client, token, owner, ref, _status, opts) do
    receive do
      :stop -> :ok
      {:DOWN, ^ref, :process, ^owner, _} -> :ok
    after
      Keyword.get(opts, :cancellation_interval_ms, 1000) ->
        status = state(client, token.req_id)

        if status in ["cancelled", "expired"] do
          notify(token, owner, status, opts)
        else
          watch(client, token, owner, ref, status, opts)
        end
    end
  end

  defp state(client, id) do
    opts = ExironClient.RequestOptions.control(client.req_options, params: [req_id: id])

    case Request.request(client, :get, "/api/request-state", opts) do
      {:ok, %{"req_id" => ^id, "state" => status}}
      when status in ["active", "cancelled", "expired", "completed", "closed"] ->
        status

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp notify(token, owner, status, opts) do
    reason = if status == "expired", do: :expired, else: :cancelled
    :atomics.put(token.flag, 1, if(reason == :expired, do: 2, else: 1))
    send(owner, {:exiron_request_cancelled, token.req_id, reason})

    try do
      Keyword.get(opts, :on_request_cancelled, fn _ -> :ok end).(%{
        request_id: token.req_id,
        reason: reason
      })
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp flush_signal(id) do
    receive do
      {:exiron_request_cancelled, ^id, _} -> flush_signal(id)
    after
      0 -> :ok
    end
  end
end
