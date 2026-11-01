defmodule ExironWeb.SessionController do
  use ExironWeb, :controller

  alias ExironWeb.Auth

  def new(conn, _params) do
    render(conn, :new, page_title: "Log in", form: session_form())
  end

  def create(conn, %{"session" => %{"password" => password}}) do
    case Auth.authenticate(password) do
      :ok ->
        return_to = get_session(conn, :user_return_to) || ~p"/"

        conn
        |> Auth.log_in()
        |> put_flash(:info, "Welcome back.")
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        render_invalid_password(conn, %{"password" => ""})
    end
  end

  def create(conn, _params) do
    render_invalid_password(conn, %{})
  end

  def delete(conn, _params), do: Auth.log_out(conn)

  defp render_invalid_password(conn, params) do
    conn
    |> put_flash(:error, "Invalid password.")
    |> render(:new, page_title: "Log in", form: session_form(params))
  end

  defp session_form(params \\ %{}), do: Phoenix.Component.to_form(params, as: :session)
end
