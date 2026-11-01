defmodule ExironWeb.Schemas.SchemaHelpersTest do
  use ExUnit.Case, async: true

  alias Exiron.Protocol
  alias ExironWeb.Schemas.SchemaHelpers
  alias OpenApiSpex.Schema

  test "builds the shared protocol schemas" do
    assert %Schema{type: :string, enum: datatypes} = SchemaHelpers.datatype()
    assert datatypes == Protocol.datatypes()

    assert %Schema{type: :array, items: %Schema{enum: capabilities}} =
             SchemaHelpers.capabilities()

    assert capabilities == Protocol.capabilities()
    assert %Schema{type: :array, items: %Schema{type: :string}} = SchemaHelpers.string_list()
    assert %Schema{type: :string, format: :"date-time"} = SchemaHelpers.date_time()
    assert %Schema{nullable: true, format: :"date-time"} = SchemaHelpers.nullable_date_time()
    assert %Schema{type: :string, nullable: true} = SchemaHelpers.nullable_string()
    assert %Schema{type: :integer, nullable: true} = SchemaHelpers.nullable_integer()
  end

  test "WebSocket schemas expose required protocol and error fields" do
    connected = ExironWeb.Schemas.WebSocketConnected.schema()
    error = ExironWeb.Schemas.WebSocketError.schema()

    assert :protocol_version in connected.required
    assert :capabilities in connected.required
    assert connected.properties.capabilities.items.enum == Protocol.capabilities()
    assert :code in error.required
    assert :error in error.required
  end
end
