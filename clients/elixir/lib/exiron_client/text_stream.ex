defmodule ExironClient.TextStream do
  @moduledoc false
  alias ExironClient.{Cancellation, Error, HandlerDeadline}

  def run(client, request, chunks, opts) do
    with {:ok, _} <- ExironClient.Idempotency.path("responses", opts),
         :ok <- check(),
         do: do_run(client, request, chunks, opts)
  end

  defp do_run(client, request, chunks, opts) do
    interval = Keyword.get(opts, :interval_ms, 500)

    if not is_integer(interval) or interval < 0,
      do: raise(ArgumentError, "interval_ms must be non-negative")

    send_opts = opts |> Keyword.delete(:interval_ms) |> Keyword.put_new(:parse_mode, "plain")

    Enum.reduce_while(chunks, {:ok, "", nil}, fn chunk, {:ok, text, last} ->
      cond do
        error = control_error() ->
          {:halt, {:error, error}}

        is_binary(chunk) and String.valid?(chunk) and
            byte_size(text) + byte_size(chunk) <= 524_288 ->
          text = text <> chunk
          units = div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)
          now = System.monotonic_time(:millisecond)

          cond do
            units > 131_072 ->
              {:halt, invalid()}

            text == "" ->
              {:cont, {:ok, text, last}}

            is_nil(last) or now - last >= interval ->
              update_opts = ExironClient.Idempotency.stream_opts(request, text, false, send_opts)

              case with(
                     :ok <- check(),
                     do: ExironClient.update_text(client, request, text, update_opts)
                   ) do
                {:ok, _} -> {:cont, {:ok, text, now}}
                error -> {:halt, error}
              end

            true ->
              {:cont, {:ok, text, last}}
          end

        true ->
          {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, "", _} ->
        invalid()

      {:ok, text, _} ->
        final_opts = ExironClient.Idempotency.stream_opts(request, text, true, send_opts)

        with :ok <- check(),
             do:
               ExironClient.respond(
                 client,
                 request,
                 "text",
                 text,
                 Keyword.put(final_opts, :final, true)
               )

      error ->
        error
    end
  end

  defp check, do: if(error = control_error(), do: {:error, error}, else: :ok)

  defp control_error do
    cond do
      HandlerDeadline.expired?() ->
        HandlerDeadline.error()

      Cancellation.reason() == :cancelled ->
        Error.new(:request_cancelled, "request cancelled by server")

      Cancellation.reason() == :expired ->
        Error.new(:request_expired, "request expired on server")

      true ->
        nil
    end
  end

  defp invalid,
    do:
      {:error,
       Error.new(
         :invalid_payload,
         "text stream must contain valid UTF-8 and fit the 131072-unit (512 KiB) logical text limit"
       )}
end
