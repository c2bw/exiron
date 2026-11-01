defmodule ExironWeb.BodyReader do
  @moduledoc false

  alias Exiron.RuntimeConfig

  def read_body(conn, opts) do
    Plug.Conn.read_body(conn, Keyword.put(opts, :length, api_body_length()))
  end

  def api_body_length do
    case Application.get_env(:exiron, :api_body_length) do
      length when is_integer(length) and length > 0 -> length
      _length -> RuntimeConfig.default(:api_body_length)
    end
  end
end
