defmodule ExironClient.DeliveryReceiptsTest do
  use ExUnit.Case, async: true
  alias ExironClient.Wire.Payload

  test "receipt opt-in travels with response and push payloads without changing defaults" do
    assert Payload.response("request", "text", "hello", delivery_receipts: true).delivery_receipts
    assert Payload.push_to_chat(123, "text", "hello", delivery_receipts: true).delivery_receipts
    refute Map.has_key?(Payload.response("request", "text", "hello"), :delivery_receipts)
    refute Map.has_key?(Payload.push("text", "hello"), :delivery_receipts)
  end
end
