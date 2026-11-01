defmodule Exiron.Benchmarks.NetworkIngress do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn
  alias Exiron.Hub
  alias Exiron.Hub.Message

  def init(opts), do: opts

  # Benchmark-only injector. Never mounted by the application's router.
  def call(%{request_path: "/__bench/ingress", method: "POST"} = conn, opts) do
    if get_req_header(conn, "authorization") == ["Bearer " <> opts[:control_token]] do
      {:ok, body, conn} = read_all(conn, "")
      %{"hook" => hook, "id" => id, "media" => media?} = Jason.decode!(body)

      :ok =
        Hub.incoming_service_message(Message.new(222, hook, "text", "/work #{id}", "fake-bot"))

      if media? do
        :ok =
          Hub.incoming_service_message(
            Message.new(222, hook, "file", :binary.copy(<<42>>, opts[:media_bytes]), "fake-bot")
          )
      end

      send_resp(conn, 200, "{}")
    else
      send_resp(conn, 401, "{}")
    end
  end

  def call(%{request_path: "/__bench/outcomes", method: "GET"} = conn, opts) do
    if get_req_header(conn, "authorization") == ["Bearer " <> opts[:control_token]] do
      outcomes = :ets.tab2list(opts[:outcomes])

      unavailable =
        Map.new(
          for {{:unavailable, hook}, count} <- outcomes, do: {Integer.to_string(hook), count}
        )

      overloaded = Enum.sum(for {{:overloaded, _hook}, count} <- outcomes, do: count)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{unavailable_by_hook: unavailable, overloaded: overloaded})
      )
    else
      send_resp(conn, 401, "{}")
    end
  end

  def call(conn, _opts), do: ExironWeb.Endpoint.call(conn, ExironWeb.Endpoint.init([]))

  defp read_all(conn, acc) do
    case read_body(conn, length: 4096) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, _, conn} -> {:error, :too_large, conn}
    end
  end
end
