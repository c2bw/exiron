defmodule Exiron.Hub.InteractionPolicy do
  @moduledoc false
  @flags ~w(request_controls followups help)
  def parse!(nil), do: %{}

  def parse!(value) when is_map(value) do
    Enum.each(value, fn {key, enabled} ->
      unless valid?(key, enabled),
        do: raise(ArgumentError, "invalid interaction setting")
    end)

    value
  end

  def parse!(_), do: raise(ArgumentError, "interaction must be a map")

  defp valid?(key, value) when key in @flags, do: is_boolean(value)

  defp valid?("description", value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 240

  defp valid?("example", value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 400

  defp valid?(key, value) when key in ["allowed_user_ids", "admin_user_ids"],
    do:
      is_list(value) and length(value) <= 1000 and
        Enum.all?(value, &(is_integer(&1) and &1 > 0 and &1 <= 9_007_199_254_740_991))

  defp valid?(_, _), do: false

  def enabled?(route, key), do: Map.get(Map.get(route, :interaction, %{}), key, false) == true

  def attach(route, value) do
    policy = parse!(value)
    if policy == %{}, do: route, else: Map.put(route, :interaction, policy)
  end

  def encode(nil), do: ""
  def encode(policy) when map_size(policy) == 0, do: ""

  def encode(policy) do
    [
      "        interaction:"
      | Enum.map(Enum.sort(policy), fn {key, value} ->
          "          #{key}: #{Jason.encode!(value)}"
        end)
    ]
    |> Enum.join("\n")
  end
end
