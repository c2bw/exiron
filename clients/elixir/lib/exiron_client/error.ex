defmodule ExironClient.Error do
  @moduledoc """
  Normalized Exiron client error.
  """

  @type t :: %__MODULE__{
          delivery: map() | nil,
          reason: atom(),
          code: String.t() | nil,
          message: String.t(),
          status: pos_integer() | nil,
          retry_after_ms: pos_integer() | nil,
          body: term() | nil
        }

  defexception [:delivery, :reason, :code, :message, :status, :retry_after_ms, :body]

  @doc "A closed, sanitized summary for routine logging; original fields remain available."
  def summary(reason) when reason in [nil, :normal, :shutdown],
    do: %{kind: :none, http_status: nil}

  def summary(%__MODULE__{reason: reason, status: status} = error) do
    kind =
      if reason in [
           :transport_error,
           :request_error,
           :hook_already_connected,
           :client_lease_lost,
           :invalid_response,
           :http_error,
           :draining,
           :handler_deadline_exceeded,
           :request_cancelled,
           :request_expired
         ], do: reason, else: :client_error

    kind = if transport_timeout?(error), do: :transport_timeout, else: kind
    %{kind: kind, http_status: if(is_integer(status) and status in 100..599, do: status)}
  end

  def summary(_), do: %{kind: :error, http_status: nil}

  @doc "Whether the API transport timed out; does not establish whether a mutation was accepted."
  def transport_timeout?(%__MODULE__{reason: :transport_error, body: reason})
      when reason in [:timeout, :connect_timeout, :pool_timeout, :etimedout], do: true

  def transport_timeout?(_), do: false

  @doc "Whether a managed request expired on the server."
  def request_expired?(%__MODULE__{reason: :request_expired}), do: true
  def request_expired?(_), do: false

  @doc "A closed error category; does not parse message text or choose retry policy."
  def classify(error) do
    cond do
      handler_deadline_exceeded?(error) -> :handler_deadline_exceeded
      client_lease_lost?(error) -> :client_lease_lost
      request_cancelled?(error) -> :request_cancelled
      request_expired?(error) -> :request_expired
      transport_timeout?(error) -> :transport_timeout
      true -> summary(error).kind
    end
  end

  @doc false
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(reason, message, opts \\ []) do
    %__MODULE__{
      delivery: Keyword.get(opts, :delivery),
      reason: reason,
      code: Keyword.get(opts, :code),
      message: message,
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
      body: Keyword.get(opts, :body)
    }
  end

  @doc false
  @spec from_response(pos_integer(), term()) :: t()
  def from_response(status, body), do: ExironClient.Wire.Error.from_response(status, body)

  @doc false
  @spec from_exception(Exception.t()) :: t()
  def from_exception(exception), do: ExironClient.Wire.Error.from_exception(exception)

  @doc """
  Returns true when an error means another client ID is currently polling with
  the same hook token.
  """
  @spec hook_already_connected?(term()) :: boolean()
  def hook_already_connected?(%__MODULE__{reason: :hook_already_connected}), do: true
  def hook_already_connected?(_error), do: false

  @doc """
  Returns true when a response or push timed out while waiting for Telegram's
  delivery result.

  Telegram may have accepted the request before the server terminated its local
  send task, so callers should treat delivery as unknown rather than safely
  retryable.
  """
  @spec telegram_delivery_timeout?(term()) :: boolean()
  def telegram_delivery_timeout?(%__MODULE__{reason: :telegram_delivery_timeout}), do: true
  def telegram_delivery_timeout?(_error), do: false

  @doc "Returns true when the request was cancelled on the server."
  def request_cancelled?(%__MODULE__{reason: :request_cancelled}), do: true
  def request_cancelled?(_), do: false

  @doc "Returns true when a send was rejected before starting because capacity was full. Retry explicitly after the retry hint; do not replay a stream from its beginning."
  @spec send_capacity_exceeded?(term()) :: boolean()
  def send_capacity_exceeded?(%__MODULE__{reason: reason})
      when reason in [:send_queue_full, :hook_send_queue_full], do: true

  def send_capacity_exceeded?(_), do: false

  @doc false
  @spec recoverable_connection_error?(term()) :: boolean()
  def recoverable_connection_error?(%__MODULE__{reason: reason}) do
    reason in [:transport_error, :hook_already_connected]
  end

  def recoverable_connection_error?(_error), do: false

  @doc false
  @spec reason_from_message(term()) :: atom()
  def reason_from_message(message),
    do: ExironClient.Wire.Error.reason_from_message(message)

  @doc "Whether new work was rejected while the operator drains the server."
  def draining?(%__MODULE__{reason: :draining}), do: true
  def draining?(_), do: false
  @doc "Whether the managed handler's local execution budget expired."
  def handler_deadline_exceeded?(%__MODULE__{reason: :handler_deadline_exceeded}), do: true
  def handler_deadline_exceeded?(_), do: false

  @doc "Whether ownership of an HTTP batch could no longer be confirmed."
  def client_lease_lost?(%__MODULE__{reason: :client_lease_lost}), do: true
  def client_lease_lost?(_), do: false
  @doc "Whether a key was reused for a different operation."
  def idempotency_conflict?(%__MODULE__{reason: :idempotency_conflict}), do: true
  def idempotency_conflict?(_), do: false
  @doc "Whether the same operation is still running."
  def idempotency_in_progress?(%__MODULE__{reason: :idempotency_in_progress}), do: true
  def idempotency_in_progress?(_), do: false
  @doc "Whether receipt capacity or a retained result is unavailable."
  def idempotency_unavailable?(%__MODULE__{reason: reason})
      when reason in [:idempotency_capacity_exceeded, :idempotency_result_unavailable], do: true

  def idempotency_unavailable?(_), do: false
end
