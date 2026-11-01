defmodule ExironClient.Idempotency do
  @moduledoc false
  alias ExironClient.{Error, Message}

  def path(operation, opts) do
    case opts[:idempotency_key] do
      nil ->
        {:ok, "/api/" <> operation}

      key when is_binary(key) ->
        if byte_size(key) in 1..128 and Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, key),
          do: {:ok, "/api/idempotent/" <> operation},
          else: {:error, Error.new(:invalid_payload, "invalid idempotency key")}

      _ ->
        {:error, Error.new(:invalid_payload, "invalid idempotency key")}
    end
  end

  def stream_opts(request, text, final, opts) do
    case opts[:idempotency_key] do
      nil ->
        opts

      base ->
        id =
          case request do
            %Message{req_id: id} -> id
            id -> id
          end

        phase = if final, do: "1", else: "0"
        digest = :crypto.hash(:sha256, base <> <<0>> <> id <> <<0>> <> phase <> <<0>> <> text)
        Keyword.put(opts, :idempotency_key, "s-" <> Base.encode16(digest, case: :lower))
    end
  end
end
