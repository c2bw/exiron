defmodule Exiron.Hub.ClientIdentity do
  @moduledoc false
  # Self-reported display metadata, never used for authorization or negotiation.
  def parse(sdk, version)
      when sdk in ["go", "elixir"] and is_binary(version) and byte_size(version) in 1..64 do
    case Version.parse(version) do
      {:ok, _} -> %{sdk: sdk, version: version}
      :error -> nil
    end
  end

  def parse(_, _), do: nil
  def normalize(%{sdk: sdk, version: version}), do: parse(sdk, version)
  def normalize(_), do: nil
end
