defmodule ExironClient.PayloadLimit do
  @moduledoc false
  alias ExironClient.Error

  def encoded_size(bytes), do: div(bytes + 2, 3) * 4

  def check_data(client, bytes, metadata) do
    encoded = encoded_size(bytes)

    if encoded > client.max_request_bytes do
      too_large(client, encoded)
    else
      check_json(client, metadata, encoded)
    end
  end

  def check_json(client, payload, extra \\ 0) do
    size = payload |> Jason.encode_to_iodata!() |> IO.iodata_length()
    check_size(client, size + extra)
  end

  def check_size(client, size) do
    if size > client.max_request_bytes, do: too_large(client, size), else: :ok
  end

  def check_options(client, opts) do
    cond do
      Keyword.has_key?(opts, :json) ->
        check_json(client, opts[:json])

      is_binary(opts[:body]) or is_list(opts[:body]) ->
        check_size(client, IO.iodata_length(opts[:body]))

      true ->
        :ok
    end
  end

  def check_album(client, items, metadata) do
    with {:ok, size} <- ExironClient.MediaItem.encoded_size(items, client.max_request_bytes),
         do: check_data(client, size, metadata)
  end

  defp too_large(client, size) do
    {:error,
     Error.new(
       :payload_too_large,
       "encoded request body is #{size} bytes; limit is #{client.max_request_bytes} bytes"
     )}
  end
end
