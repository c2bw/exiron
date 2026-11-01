defmodule ExironClient.PollerOptions do
  @moduledoc false

  alias ExironClient.Validation

  @default_interval_ms 1_000
  @default_disconnect_timeout_ms 2_000

  def build!(opts) when is_list(opts) do
    graceful = Keyword.get(opts, :graceful_shutdown, false)
    unless is_boolean(graceful), do: raise(ArgumentError, ":graceful_shutdown must be a boolean")

    opts =
      if graceful and Keyword.get(opts, :transport, :websocket) == :http,
        do: Keyword.put(opts, :http_lease_renewal, true),
        else: opts

    client = Keyword.fetch!(opts, :client)

    if graceful and not (is_binary(client.client_id) and byte_size(client.client_id) in 1..128),
      do: raise(ArgumentError, "graceful shutdown requires a client ID of 1..128 bytes")

    handler = Keyword.fetch!(opts, :handler)

    # Validate every local option before making a shared discovery request.
    handler_options =
      handler_options!(opts) ++
        ExironClient.Cancellation.options!(opts, client, false) ++
        ExironClient.HandlerReporting.options!(opts, client, false) ++
        ExironClient.HTTPLease.options!(opts, client, false) ++
        ExironClient.RuntimeReporting.options!(opts, client)

    required =
      for {key, capability} <- [
            runtime_reporting: "client_runtime_reporting",
            graceful_shutdown: "client_retirement",
            cooperative_cancellation: "cooperative_cancellation",
            report_handler_failures: "handler_failure_reporting",
            http_lease_renewal: "http_lease_renewal"
          ],
          Keyword.get(opts, key, false) == true,
          do: capability

    handler = function!(handler, 1, ":handler must be a one-argument function")
    interval = Validation.positive_integer_option!(opts, :interval_ms, @default_interval_ms)

    disconnect_timeout =
      Validation.positive_integer_option!(
        opts,
        :disconnect_timeout_ms,
        @default_disconnect_timeout_ms
      )

    config = %{
      client: client,
      graceful_shutdown: graceful,
      handler_options: handler_options,
      handler: handler,
      interval_ms: interval,
      disconnect_timeout_ms: disconnect_timeout,
      on_connect:
        opts
        |> Keyword.get(:on_connect, fn -> :ok end)
        |> function!(0, ":on_connect must be a zero-argument function"),
      on_protocol:
        opts
        |> Keyword.get(:on_protocol, fn _protocol -> :ok end)
        |> function!(1, ":on_protocol must be a one-argument function"),
      on_disconnect:
        opts
        |> Keyword.get(:on_disconnect, fn _reason -> :ok end)
        |> function!(1, ":on_disconnect must be a one-argument function")
    }

    auto? =
      Keyword.get(opts, :runtime_reporting, :auto) == :auto and
        is_binary(Map.get(client, :client_id)) and byte_size(client.client_id) in 1..128

    protocol = ExironClient.FeatureNegotiation.discover!(client, required, auto?)

    if auto? and not is_nil(protocol) and
         ExironClient.Protocol.supports?(protocol, "client_runtime_reporting") do
      reporting = ExironClient.RuntimeReporting.options!([runtime_reporting: true], client)
      %{config | handler_options: config.handler_options ++ reporting}
    else
      config
    end
  end

  defp handler_options!(opts) do
    timeout = Keyword.get(opts, :handler_timeout_ms, 0)

    unless is_integer(timeout) and timeout >= 0,
      do: raise(ArgumentError, ":handler_timeout_ms must be a non-negative integer")

    policy = Keyword.get(opts, :handler_failure_policy, :stop)

    unless policy in [:stop, :quarantine],
      do: raise(ArgumentError, ":handler_failure_policy must be :stop or :quarantine")

    quarantine = Keyword.get(opts, :quarantine)

    if policy == :quarantine and not match?({:ok, _}, ExironClient.Quarantine.stats(quarantine)),
      do:
        raise(ArgumentError, "quarantine policy requires a running ExironClient.Quarantine store")

    on_quarantined =
      function!(
        Keyword.get(opts, :on_quarantined, fn _ -> :ok end),
        1,
        ":on_quarantined must be a one-argument function"
      )

    concurrency = Validation.positive_integer_option!(opts, :handler_concurrency, 1)
    if concurrency > 64, do: raise(ArgumentError, "handler_concurrency must be 1..64")
    order_by_chat = Keyword.get(opts, :handler_order_by_chat, false)

    unless is_boolean(order_by_chat),
      do: raise(ArgumentError, "handler_order_by_chat must be a boolean")

    max_attempts = Validation.positive_integer_option!(opts, :handler_max_attempts, 1)
    if max_attempts > 10, do: raise(ArgumentError, "handler_max_attempts must be 1..10")
    delay = Validation.positive_integer_option!(opts, :handler_retry_delay_ms, 250)

    callback =
      function!(
        Keyword.get(opts, :on_handler_error, fn _failure -> :ok end),
        1,
        ":on_handler_error must be a one-argument function"
      )

    [
      handler_timeout_ms: timeout,
      failure_policy: policy,
      quarantine: if(policy == :quarantine, do: quarantine),
      on_quarantined: on_quarantined,
      concurrency: concurrency,
      order_by_chat: order_by_chat,
      max_attempts: max_attempts,
      retry_delay_ms: delay,
      on_error: callback
    ]
  end

  defp function!(fun, arity, _message) when is_function(fun, arity), do: fun
  defp function!(_fun, _arity, message), do: raise(ArgumentError, message)
end
