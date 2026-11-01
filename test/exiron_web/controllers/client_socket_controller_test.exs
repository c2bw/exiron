defmodule ExironWeb.ClientSocketControllerTest do
  use ExironWeb.ConnCase, async: false

  alias Exiron.Hub
  alias Exiron.Hub.Telegram
  alias ExironWeb.ClientSocketController
  import Exiron.Support.RouterHelper

  setup do
    :ok = Hub.configure(load_router!("client-socket-controller"), Telegram.new([]))
    :ok
  end

  test "renders a missing-token error before attempting a websocket upgrade", %{conn: conn} do
    conn = ClientSocketController.connect(conn, %{"client_id" => "client"})

    assert conn.status == 401
    assert %{"error" => "missing bearer token"} = Jason.decode!(conn.resp_body)
  end

  test "renders an invalid-token error before attempting a websocket upgrade", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")
      |> ClientSocketController.connect(%{"client_id" => "client"})

    assert conn.status == 401
    assert %{"error" => "invalid token"} = Jason.decode!(conn.resp_body)
  end
end
