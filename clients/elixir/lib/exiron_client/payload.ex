defmodule ExironClient.Payload do
  @moduledoc false

  alias ExironClient.Wire.Payload, as: WirePayload

  defdelegate encode(data), to: WirePayload
  defdelegate decode_message(data), to: WirePayload
end
