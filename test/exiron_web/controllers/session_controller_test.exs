defmodule ExironWeb.SessionControllerTest do
  use ExironWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @sixty_days_in_seconds 60 * 24 * 60 * 60

  test "redirects unauthenticated dashboard requests to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "renders login form", %{conn: conn} do
    conn = get(conn, ~p"/login")

    assert html_response(conn, 200) =~ ~s(id="login-form")
  end

  test "rendering the login page does not consume the authentication rate limit", %{conn: conn} do
    conn =
      Enum.reduce(1..10, conn, fn _request, conn ->
        conn = get(conn, ~p"/login")
        assert html_response(conn, 200) =~ ~s(id="login-form")
        recycle(conn)
      end)

    conn = log_in(conn)

    assert redirected_to(conn) == ~p"/"
  end

  test "rate limits login before parsing its request body", %{conn: conn} do
    now = System.system_time(:second)

    :ets.insert(
      :rate_limit_entries,
      {{:dashboard_authentication, "127.0.0.1", now}, 10}
    )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/login", "{")

    assert %{"error" => "too many requests"} = json_response(conn, 429)
  end

  test "API authentication traffic does not consume the dashboard login budget", %{conn: conn} do
    now = System.system_time(:second)

    :ets.insert(
      :rate_limit_entries,
      {{:api_authentication, "127.0.0.1", now}, 10}
    )

    conn = log_in(conn)

    assert redirected_to(conn) == ~p"/"
  end

  test "rejects invalid password", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"session" => %{"password" => "wrong"}})

    assert html_response(conn, 200) =~ ~s(id="login-form")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid password."
  end

  test "logs in with configured password", %{conn: conn} do
    conn = log_in(conn)

    assert redirected_to(conn) == ~p"/"

    assert %{
             "authenticated_at" => authenticated_at,
             "credential_fingerprint" => credential_fingerprint
           } = get_session(conn, :exiron_authenticated_at)

    assert is_integer(authenticated_at)
    assert is_binary(credential_fingerprint)
  end

  test "sets a persistent login cookie for 60 days", %{conn: conn} do
    conn = log_in(conn)

    assert %{max_age: @sixty_days_in_seconds} =
             Map.fetch!(conn.resp_cookies, "_exiron_key")
  end

  test "marks the login cookie secure when production cookie security is enabled", %{conn: conn} do
    previous = Application.get_env(:exiron, :secure_session_cookie, false)
    Application.put_env(:exiron, :secure_session_cookie, true)
    on_exit(fn -> Application.put_env(:exiron, :secure_session_cookie, previous) end)

    conn = log_in(conn)

    assert %{secure: true} = Map.fetch!(conn.resp_cookies, "_exiron_key")
  end

  test "rejects expired dashboard sessions", %{conn: conn} do
    conn = log_in(conn)
    session = get_session(conn, :exiron_authenticated_at)

    expired_session =
      Map.put(
        session,
        "authenticated_at",
        System.system_time(:second) - session_max_age_seconds() - 1
      )

    conn =
      conn
      |> recycle()
      |> init_test_session(%{exiron_authenticated_at: expired_session})
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/login"
  end

  test "password rotation invalidates existing dashboard sessions", %{conn: conn} do
    original_password = Application.fetch_env!(:exiron, :dashboard_password)
    on_exit(fn -> Application.put_env(:exiron, :dashboard_password, original_password) end)

    conn = log_in(conn)
    Application.put_env(:exiron, :dashboard_password, "rotated-password")

    conn =
      conn
      |> recycle()
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/login"
  end

  test "redirects authenticated users away from login", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> recycle()
      |> get(~p"/login")

    assert redirected_to(conn) == ~p"/"
  end

  test "logs out", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> recycle()
      |> delete(~p"/logout")

    assert redirected_to(conn) == ~p"/login"

    conn =
      conn
      |> recycle()
      |> get(~p"/login")

    assert html_response(conn, 200) =~ ~s(id="login-form")
  end

  test "logs out through a URL-encoded method override", %{conn: conn} do
    conn =
      conn
      |> log_in()
      |> recycle()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(~p"/logout", "_method=delete")

    assert redirected_to(conn) == ~p"/login"
  end

  defp session_max_age_seconds do
    Application.fetch_env!(:exiron, :dashboard_session_max_age_seconds)
  end
end
