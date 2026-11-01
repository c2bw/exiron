defmodule ExironWeb.UploadLimitTest do
  use ExironWeb.ConnCase, async: false
  alias Exiron.Hub

  setup do
    :ok = Hub.configure(Exiron.HubCase.load_router!(), Exiron.Hub.Telegram.new([]))
    old = Application.fetch_env(:exiron, :api_body_length)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:exiron, :api_body_length, value)
        :error -> Application.delete_env(:exiron, :api_body_length)
      end
    end)

    :ok
  end

  test "authenticated bodies obey the upload limit before changing Hub state", %{conn: conn} do
    body = Jason.encode!(%{req_id: "missing-request"})
    Application.put_env(:exiron, :api_body_length, byte_size(body) - 1)
    before = :sys.get_state(Hub)

    assert_error_sent 413, fn ->
      conn |> auth() |> post("/api/cancellations", body)
    end

    assert :sys.get_state(Hub) == before

    Application.put_env(:exiron, :api_body_length, byte_size(body))
    assert conn |> auth() |> post("/api/cancellations", body) |> json_response(404)
  end

  defp auth(conn) do
    conn
    |> put_req_header("authorization", "Bearer ai-token")
    |> put_req_header("content-type", "application/json")
  end
end
