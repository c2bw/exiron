defmodule Exiron.TelegramAdapter do
  @moduledoc false
  @behaviour ExGram.Adapter

  # Build a fixed response-key whitelist from the SDK schema at compile time.
  # Models may not yet be loaded in a fresh release when a response arrives.
  # A dynamic "existing atoms" conversion could silently lose their fields.
  _ = Application.load(:ex_gram)

  @model_keys :ex_gram
              |> Application.spec(:modules)
              |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.ExGram.Model."))
              |> Enum.flat_map(fn module ->
                Code.ensure_loaded!(module)

                if function_exported?(module, :__struct__, 0),
                  do: Map.keys(module.__struct__()) -- [:__struct__],
                  else: []
              end)
              |> Enum.uniq()
              |> Map.new(&{Atom.to_string(&1), &1})

  # ExGram's bundled Req adapter currently discards object-shaped error
  # parameters. Preserve retry_after and disable implicit transport retries.
  @impl true
  def request(_verb, path, body, opts) do
    options = [
      method: :post,
      url: path,
      base_url: ExGram.Config.get(:ex_gram, :base_url, "https://api.telegram.org"),
      retry: false,
      redirect: false,
      decode_body: false,
      pool_timeout: Keyword.get(opts, :pool_timeout, 5_000),
      receive_timeout: Keyword.get(opts, :receive_timeout, 60_000)
    ]

    with {:ok, response} <-
           Req.request(
             options ++ pool_options(opts) ++ body_options(body) ++ Keyword.take(opts, [:plug])
           ),
         {:ok, decoded} <- Jason.decode(response.body) do
      result(response.status, decoded)
    else
      {:error, _} ->
        {:error, %ExGram.Error{code: :transport_error, message: "Telegram request failed"}}
    end
  end

  # Req forbids combining a named pool with per-request connect_options.
  # Managed pools preserve the default connect timeout; explicitly supplied
  # Finch pools own their connection configuration instead.
  defp pool_options(opts) do
    case Keyword.get(opts, :finch) do
      nil ->
        [
          connect_options: [
            timeout: Keyword.get(opts, :connect_timeout, 30_000),
            protocols: [:http1]
          ]
        ]

      finch ->
        [finch: finch]
    end
  end

  defp result(status, %{"ok" => true, "result" => result}) when status in 200..299,
    do: {:ok, existing_keys(result)}

  defp result(_status, %{"ok" => false, "error_code" => code, "description" => message} = body),
    do:
      {:error,
       %ExGram.Error{
         code: code,
         message: message,
         metadata: %{parameters: Map.get(body, "parameters", %{})}
       }}

  defp result(_status, _body),
    do: {:error, %ExGram.Error{code: :invalid_response, message: "Invalid Telegram response"}}

  defp body_options({:multipart, parts}) do
    parts =
      Enum.map(parts, fn
        {:file, name, path} -> {name, File.stream!(path, 2048)}
        {:file_content, name, content, filename} -> {name, {content, filename: filename}}
        part -> part
      end)

    [form_multipart: parts]
  end

  defp body_options(body),
    do: [body: ExGram.Adapter.encode(body), headers: [{"content-type", "application/json"}]]

  defp existing_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {existing_key(key), existing_keys(value)} end)

  defp existing_keys(list) when is_list(list), do: Enum.map(list, &existing_keys/1)
  defp existing_keys(value), do: value

  defp existing_key(key), do: Map.get(@model_keys, key, key)
end
