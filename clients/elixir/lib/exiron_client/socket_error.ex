defmodule ExironClient.SocketError do
  @moduledoc false

  alias ExironClient.{Error, Wire}

  def disconnect_error(_reason, %{last_error: %Error{} = error}), do: error

  def disconnect_error(%WebSockex.RequestError{code: code} = reason, _state) do
    Error.new(handshake_error_reason(code), Exception.message(reason),
      status: code,
      body: reason
    )
  end

  def disconnect_error(reason, _state) do
    if replaced_close?(reason) do
      Error.new(:client_replaced, "websocket client replaced", body: reason)
    else
      Error.new(:transport_error, inspect(reason), body: reason)
    end
  end

  def socket_error(message, frame) do
    code = Map.get(frame, "code")

    Error.new(Wire.Error.reason_from_code(code, message), message,
      code: code,
      status: 409,
      retry_after_ms: Map.get(frame, "retry_after_ms"),
      body: frame
    )
  end

  defp handshake_error_reason(429), do: :rate_limited
  defp handshake_error_reason(401), do: :invalid_token
  defp handshake_error_reason(403), do: :invalid_token
  defp handshake_error_reason(503), do: :server_disabled
  defp handshake_error_reason(409), do: :hook_already_connected
  defp handshake_error_reason(_status), do: :server_error

  defp replaced_close?({:remote, 1000, "replaced"}), do: true
  defp replaced_close?({:local, 1000, "replaced"}), do: true
  defp replaced_close?({_, 1000, "replaced"}), do: true
  defp replaced_close?(_reason), do: false
end
