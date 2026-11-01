defmodule ExironClient.Validation do
  @moduledoc false

  def positive_integer!(value, _message) when is_integer(value) and value > 0, do: value
  def positive_integer!(_value, message), do: raise(ArgumentError, message)

  def positive_integer_option!(opts, key, default \\ nil) do
    opts
    |> Keyword.get(key, default)
    |> positive_integer!("#{key} must be a positive integer")
  end

  def bearer_header(token), do: {"authorization", "Bearer " <> token}
end
