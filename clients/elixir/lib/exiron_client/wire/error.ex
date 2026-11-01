defmodule ExironClient.Wire.Error do
  @moduledoc false

  alias ExironClient.{Error, Protocol.Generated}

  @reason_by_message %{
    "missing_bearer_token" => :missing_token,
    "invalid_token" => :invalid_token,
    "exiron_disabled" => :server_disabled,
    "request_not_found" => :request_not_found,
    "request_not_assigned" => :request_not_assigned,
    "hook_already_connected" => :hook_already_connected,
    "chat_not_pushable" => :chat_not_pushable,
    "invalid_client_id" => :invalid_client_id,
    "invalid_chat_id" => :invalid_chat_id,
    "invalid_datatype" => :invalid_datatype,
    "invalid_payload" => :invalid_payload,
    "invalid_base64_data" => :invalid_payload,
    "telegram_bot_not_configured" => :server_disabled,
    "telegram_bot_forbidden" => :server_disabled,
    "telegram_bot_unauthorized" => :server_disabled,
    "send_queue_full" => :send_queue_full,
    "hook_send_queue_full" => :hook_send_queue_full,
    "send_unavailable" => :send_unavailable,
    "telegram_delivery_result_timed_out" => :telegram_delivery_timeout,
    "telegram_file_path_empty" => :server_error,
    "telegram_file_too_large" => :payload_too_large,
    "too_many_requests" => :rate_limited,
    "internal_error" => :server_error
  }

  @spec from_response(pos_integer(), term()) :: Error.t()
  def from_response(status, %{"error" => message} = body) when is_binary(message) do
    code = valid_code(body["code"])

    Error.new(reason_from_code(code, message), message,
      delivery: if(is_map(body["delivery"]), do: body["delivery"]),
      code: code,
      status: status,
      retry_after_ms: retry_after_ms(body),
      body: body
    )
  end

  def from_response(status, body) do
    Error.new(:http_error, "Exiron server returned HTTP #{status}", status: status, body: body)
  end

  @spec from_exception(Exception.t()) :: Error.t()
  def from_exception(%Req.TransportError{reason: reason} = exception) do
    Error.new(:transport_error, Exception.message(exception), body: reason)
  end

  def from_exception(exception) do
    Error.new(:request_error, Exception.message(exception), body: exception)
  end

  @spec reason_from_message(term()) :: atom()
  def reason_from_message(message) do
    Map.get(@reason_by_message, message_key(message), :server_error)
  end

  @spec reason_from_code(term(), term()) :: atom()
  def reason_from_code(code, fallback_message \\ nil)

  def reason_from_code(code, fallback_message) do
    case Generated.error_reason(code) do
      {:ok, reason} -> reason
      :error -> reason_from_message(fallback_message)
    end
  end

  defp valid_code(code), do: if(Generated.known_error_code?(code), do: code)

  defp message_key(message) when not is_binary(message), do: nil

  defp message_key(message) do
    message
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp retry_after_ms(%{"retry_after_ms" => value}) when is_integer(value) and value > 0,
    do: value

  defp retry_after_ms(_body), do: nil
end
