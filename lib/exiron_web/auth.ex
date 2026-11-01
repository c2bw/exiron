defmodule ExironWeb.Auth do
  @moduledoc false

  import Phoenix.Controller, only: [current_path: 1]
  import Phoenix.LiveView
  import Plug.Conn

  alias ExironWeb.Session

  @session_key :exiron_authenticated_at
  @authenticated_at_key "authenticated_at"
  @credential_fingerprint_key "credential_fingerprint"

  def init(action), do: action

  def call(conn, :fetch_current_scope), do: fetch_current_scope(conn, [])
  def call(conn, :redirect_if_authenticated), do: redirect_if_authenticated(conn, [])
  def call(conn, :require_authenticated_user), do: require_authenticated_user(conn, [])

  def log_in(conn) do
    conn
    |> renew_session()
    |> put_session(@session_key, session_data())
  end

  def log_out(conn) do
    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> Phoenix.Controller.redirect(to: "/login")
  end

  def authenticated?(conn), do: conn |> get_session(@session_key) |> valid_session?()

  def fetch_current_scope(conn, _opts) do
    assign(conn, :current_scope, current_scope(conn))
  end

  def redirect_if_authenticated(conn, _opts) do
    if authenticated?(conn) do
      conn
      |> Phoenix.Controller.redirect(to: "/")
      |> halt()
    else
      conn
    end
  end

  def require_authenticated_user(conn, _opts) do
    if authenticated?(conn) do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> Phoenix.Controller.redirect(to: "/login")
      |> halt()
    end
  end

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_scope, current_scope(session))}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    if authenticated_session?(session) do
      {:cont, Phoenix.Component.assign(socket, :current_scope, current_scope(session))}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: "/login")

      {:halt, socket}
    end
  end

  def authenticate(password) when is_binary(password) do
    configured = configured_password()

    if configured != "" and Plug.Crypto.secure_compare(password, configured) do
      :ok
    else
      {:error, :invalid_credentials}
    end
  end

  def authenticate(_password), do: {:error, :invalid_credentials}

  defp configured_password do
    Application.get_env(:exiron, :dashboard_password, "")
  end

  defp authenticated_session?(session) do
    session
    |> Map.get(Atom.to_string(@session_key))
    |> valid_session?()
  end

  defp current_scope(%Plug.Conn{} = conn), do: session_scope(get_session(conn, @session_key))

  defp current_scope(%{} = session),
    do: session_scope(Map.get(session, Atom.to_string(@session_key)))

  defp session_scope(session_data) do
    if valid_session?(session_data) do
      %{authenticated_at: Map.fetch!(session_data, @authenticated_at_key)}
    else
      nil
    end
  end

  defp session_data do
    %{
      @authenticated_at_key => System.system_time(:second),
      @credential_fingerprint_key => credential_fingerprint(configured_password())
    }
  end

  defp valid_session?(%{
         @authenticated_at_key => authenticated_at,
         @credential_fingerprint_key => credential_fingerprint
       })
       when is_integer(authenticated_at) and is_binary(credential_fingerprint) do
    session_fresh?(authenticated_at) and credential_current?(credential_fingerprint)
  end

  defp valid_session?(_session_data), do: false

  defp session_fresh?(authenticated_at) do
    age_seconds = System.system_time(:second) - authenticated_at
    age_seconds >= 0 and age_seconds < Session.max_age_seconds()
  end

  defp credential_current?(credential_fingerprint) do
    configured = configured_password()

    configured != "" and
      Plug.Crypto.secure_compare(
        credential_fingerprint,
        credential_fingerprint(configured)
      )
  end

  defp credential_fingerprint(password) do
    secret_key_base =
      :exiron
      |> Application.fetch_env!(ExironWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret_key_base, password)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
