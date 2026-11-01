defmodule ExironClient.SocketUrl do
  @moduledoc false

  def build(client) do
    uri = URI.parse(client.base_url)

    scheme =
      case uri.scheme do
        "http" -> "ws"
        "https" -> "wss"
        scheme -> scheme
      end

    query =
      URI.encode_query(%{
        client_id: client.client_id,
        listen: ExironClient.listen_param(client.listen?)
      })

    %{uri | scheme: scheme, path: join_url_path(uri.path, "/api/socket"), query: query}
    |> URI.to_string()
  end

  defp join_url_path(base_path, child_path) do
    base_path = base_path |> to_string() |> String.trim_trailing("/")
    child_path = String.trim_leading(child_path, "/")

    if base_path == "" do
      "/" <> child_path
    else
      base_path <> "/" <> child_path
    end
  end
end
