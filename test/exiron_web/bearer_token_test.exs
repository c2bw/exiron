defmodule ExironWeb.BearerTokenTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2]

  alias ExironWeb.BearerToken

  test "extracts and trims a bearer credential" do
    conn = conn(:get, "/") |> put_req_header("authorization", "Bearer  token ")

    assert BearerToken.from_conn(conn) == "token"
  end

  test "accepts bearer authentication schemes case-insensitively" do
    for scheme <- ["bearer", "BEARER", "BeArEr"] do
      conn = conn(:get, "/") |> put_req_header("authorization", "#{scheme} token")

      assert BearerToken.from_conn(conn) == "token"
    end
  end

  test "rejects missing and unsupported authorization schemes" do
    assert BearerToken.from_conn(conn(:get, "/")) == nil

    conn = conn(:get, "/") |> put_req_header("authorization", "Basic credentials")
    assert BearerToken.from_conn(conn) == nil
  end
end
