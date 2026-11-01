defmodule ExironWeb.ExironController.ErrorResponse do
  @moduledoc false

  require Logger

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias Exiron.Protocol

  def render(conn, {:delivery_error, reason, diagnostic}) do
    conn = Plug.Conn.assign(conn, :delivery_diagnostics, diagnostic)

    case reason do
      %ExGram.Error{code: 403} -> render_error(conn, :telegram_bot_forbidden)
      %ExGram.Error{} -> render_error(conn, :internal_error)
      reason when is_atom(reason) -> render(conn, reason)
      reason when is_binary(reason) -> render_error(conn, :invalid_payload)
      _ -> render_error(conn, :internal_error)
    end
  end

  def render(conn, {:hook_already_connected, retry_after_ms}) do
    render_error(conn, :hook_already_connected, %{retry_after_ms: retry_after_ms})
  end

  def render(conn, reason)
      when reason in [
             :send_queue_full,
             :hook_send_queue_full,
             :idempotency_in_progress,
             :idempotency_capacity_exceeded
           ] do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "1")
    |> render_error(reason, %{retry_after_ms: 1000})
  end

  def render(conn, %ExGram.Error{code: 403}) do
    render_error(conn, :telegram_bot_forbidden)
  end

  def render(conn, reason) when is_binary(reason),
    do: render_error(conn, :invalid_payload, %{error: reason})

  def render(conn, reason) when is_atom(reason) do
    log_internal_error(reason)
    render_error(conn, reason)
  end

  def render(conn, reason) do
    log_internal_error(reason)
    render_error(conn, :internal_error)
  end

  def message(reason) when is_atom(reason), do: Protocol.error_message(reason)
  def message({_status, message}) when is_binary(message), do: message
  def message(_reason), do: Protocol.error_message(:internal_error)

  defp render_error(conn, reason, extra \\ %{}) do
    descriptor = Protocol.error_descriptor(reason)

    extra =
      if conn.assigns[:delivery_diagnostics],
        do: Map.put(extra, :delivery, conn.assigns.delivery_diagnostics),
        else: extra

    conn
    |> put_status(descriptor.status)
    |> json(Protocol.error_payload(reason, extra))
  end

  defp log_internal_error(reason) do
    if Protocol.error_code(reason) == "internal_error" do
      Logger.warning("unhandled error reason: #{inspect(reason)}")
    end
  end
end
