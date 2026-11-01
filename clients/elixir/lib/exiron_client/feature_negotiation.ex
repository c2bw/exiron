defmodule ExironClient.FeatureNegotiation do
  @moduledoc false

  def require!(client, required) do
    _ = discover!(client, required, false)
    :ok
  end

  def discover!(_client, [], false), do: nil

  def discover!(client, required, optional?) do
    control = %{
      client
      | reconnect_backoff: Keyword.put(client.reconnect_backoff, :max_retry_time_ms, 0)
    }

    control =
      if optional? and required == [] do
        request_options =
          Keyword.merge(control.req_options, receive_timeout: 1000, pool_timeout: 1000)

        request_options =
          if Keyword.has_key?(request_options, :finch),
            do: request_options,
            else:
              Keyword.put(
                request_options,
                :connect_options,
                Keyword.put(Keyword.get(request_options, :connect_options, []), :timeout, 1000)
              )

        %{control | req_options: request_options}
      else
        control
      end

    case ExironClient.capabilities(control) do
      {:ok, protocol} ->
        Enum.each(required, fn capability ->
          unless ExironClient.Protocol.supports?(protocol, capability),
            do: raise(ArgumentError, "server does not support #{capability}")
        end)

        protocol

      _ when optional? and required == [] ->
        nil

      _ ->
        raise ArgumentError, "cannot negotiate client capabilities"
    end
  end
end
