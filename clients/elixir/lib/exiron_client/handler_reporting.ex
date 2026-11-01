defmodule ExironClient.HandlerReporting do
  @moduledoc false
  alias ExironClient.Request

  def options!(opts, client, verify? \\ true) do
    case Keyword.get(opts, :report_handler_failures, false) do
      false ->
        []

      true ->
        control = %{
          client
          | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)
        }

        if verify?,
          do: ExironClient.FeatureNegotiation.require!(control, ["handler_failure_reporting"])

        [reporting_client: control]

      _ ->
        raise ArgumentError, "report_handler_failures must be a boolean"
    end
  end

  def report(message, opts, attempt, max, state, error \\ nil) do
    client = opts[:reporting_client]
    batch = opts[:delivery_id]

    if client && is_binary(batch) && batch != "" && is_binary(message.req_id) &&
         message.req_id != "" && message.msgtype != "listen" do
      payload = %{
        req_id: message.req_id,
        client_id: client.client_id,
        delivery_id: batch,
        attempt: attempt,
        max_attempts: max,
        state: state
      }

      payload =
        if state == "recovered", do: payload, else: Map.put(payload, :category, category(error))

      request_opts = [json: payload, receive_timeout: 1000, pool_timeout: 1000]

      request_opts =
        if Keyword.has_key?(client.req_options, :finch),
          do: request_opts,
          else:
            Keyword.put(
              request_opts,
              :connect_options,
              client.req_options
              |> Keyword.get(:connect_options, [])
              |> Keyword.put(:timeout, 1000)
            )

      Request.request(client, :post, "/api/handler-reports", request_opts)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp category(%ExironClient.Error{}), do: "client_error"
  defp category(%{__exception__: true}), do: "exception"
  defp category(_), do: "handler_error"
end
