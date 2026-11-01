defmodule ExironClient.Wire.Auth do
  @moduledoc false

  @spec request(String.t() | nil) :: map()
  def request(token), do: %{hook_token: token}

  @spec decode(map()) :: ExironClient.Auth.t()
  def decode(%{} = response), do: ExironClient.Auth.from_wire(response)
end
