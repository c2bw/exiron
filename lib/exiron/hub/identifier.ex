defmodule Exiron.Hub.Identifier do
  @moduledoc """
  Generates opaque, URL-safe identifiers shared by hub requests, deliveries,
  and runtime history entries.
  """

  @byte_length 16

  @spec new() :: String.t()
  def new do
    @byte_length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
