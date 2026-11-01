defmodule ExironWeb.Plugs.BrowserFormParser do
  @moduledoc false

  @parser_opts Plug.Parsers.init(
                 parsers: [:urlencoded],
                 pass: ["*/*"],
                 length: 64 * 1024
               )

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if api_path?(path) do
      conn
    else
      Plug.Parsers.call(conn, @parser_opts)
    end
  end

  defp api_path?("/api"), do: true
  defp api_path?("/api/" <> _path), do: true
  defp api_path?(_path), do: false
end
