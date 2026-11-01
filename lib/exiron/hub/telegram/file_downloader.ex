defmodule Exiron.Hub.Telegram.FileDownloader do
  @moduledoc false

  def download(token, file_id, opts) do
    get_file = Keyword.fetch!(opts, :get_file)
    http_get = Keyword.fetch!(opts, :http_get)
    max_download_bytes = Keyword.fetch!(opts, :max_download_bytes)

    with {:ok, file} <- get_file.(file_id, token: token),
         path when is_binary(path) and path != "" <- file_path(file),
         {:ok, response} <-
           http_get.(file_url(token, path),
             finch: Exiron.Finch,
             into: limited_body_collector(max_download_bytes)
           ),
         response = finalize_download_response(response),
         :ok <- validate_download_response(response) do
      {:ok, response.body}
    else
      nil -> {:error, :telegram_file_path_empty}
      "" -> {:error, :telegram_file_path_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  # Req streams chunks through this collector, so we can halt oversized Telegram
  # downloads before the whole file is accumulated in memory.
  defp limited_body_collector(max_download_bytes) do
    fn {:data, data}, {request, response} ->
      size = download_size(response) + byte_size(data)
      chunks = download_chunks(response)

      response = put_download_size(response, size)

      if size > max_download_bytes do
        response = Req.Response.put_private(response, :exiron_body_too_large, true)
        {:halt, {request, response}}
      else
        response = put_download_chunks(response, [data | chunks])
        {:cont, {request, response}}
      end
    end
  end

  defp finalize_download_response(
         %Req.Response{private: %{exiron_body_too_large: true}} = response
       ),
       do: response

  defp finalize_download_response(response) do
    case download_chunks(response) do
      [] ->
        response

      chunks ->
        %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp validate_download_response(%Req.Response{private: %{exiron_body_too_large: true}}),
    do: {:error, :telegram_file_too_large}

  defp validate_download_response(%Req.Response{status: status}) when status in 200..299, do: :ok

  defp validate_download_response(%Req.Response{status: status}),
    do: {:error, {:bad_status, status}}

  defp download_size(response), do: Req.Response.get_private(response, :exiron_body_size, 0)

  defp put_download_size(response, size),
    do: Req.Response.put_private(response, :exiron_body_size, size)

  defp put_download_chunks(response, chunks),
    do: Req.Response.put_private(response, :exiron_body_chunks, chunks)

  defp download_chunks(response), do: Req.Response.get_private(response, :exiron_body_chunks, [])

  defp file_path(file) when is_map(file),
    do: Map.get(file, :file_path) || Map.get(file, "file_path")

  defp file_path(_file), do: nil

  defp file_url(token, path), do: "https://api.telegram.org/file/bot#{token}/#{path}"
end
