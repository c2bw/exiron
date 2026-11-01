defmodule Exiron.Hub.IdentifierTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.Identifier

  test "generates URL-safe identifiers from 128 bits" do
    identifier = Identifier.new()

    assert {:ok, bytes} = Base.url_decode64(identifier, padding: false)
    assert byte_size(bytes) == 16
  end
end
