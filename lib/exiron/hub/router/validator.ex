defmodule Exiron.Hub.Router.Validator do
  @moduledoc false

  alias Exiron.Hub.HookToken

  def validate(definitions) do
    with {:ok, definitions} <- validate_root(definitions),
         {:ok, hooks} <- validate_hooks(Map.get(definitions, "hooks")),
         {:ok, bot_names} <- validate_bot_names(Map.get(definitions, "bots")) do
      {:ok, %{definitions: definitions, hooks: hooks, bot_names: bot_names}}
    end
  end

  def normalize_bot_tag(tag) when is_binary(tag) do
    tag
    |> String.trim()
    |> String.trim_leading("@")
  end

  def normalize_bot_tag(_tag), do: ""

  defp validate_root(definitions) when is_map(definitions), do: {:ok, definitions}
  defp validate_root(_definitions), do: {:error, "routes file must contain a map"}

  defp validate_hooks(nil), do: {:ok, %{}}

  defp validate_hooks(hooks) when is_map(hooks) do
    with {:ok, hooks} <-
           validated_string_map(
             hooks,
             &valid_hook_name/1,
             "hook names must be non-empty strings",
             fn name -> "hook #{inspect(name)} token must be a non-empty string" end
           ) do
      hooks
      |> Map.new(fn {name, token} -> {name, HookToken.hash(token)} end)
      |> validate_unique_hook_tokens()
    end
  end

  defp validate_hooks(_hooks), do: {:error, "hooks must be a map"}

  defp validate_unique_hook_tokens(hooks) do
    tokens = Map.values(hooks)

    if MapSet.size(MapSet.new(tokens)) == length(tokens) do
      {:ok, hooks}
    else
      {:error, "hook tokens must be unique"}
    end
  end

  defp validate_bot_names(nil), do: {:ok, %{}}

  defp validate_bot_names(%{"telegram" => telegram}) when is_map(telegram) do
    validated_string_map(
      telegram,
      &normalize_bot_tag/1,
      "telegram bot tags must be non-empty strings",
      fn tag -> "telegram bot #{inspect(tag)} name must be a non-empty string" end
    )
  end

  defp validate_bot_names(%{"telegram" => _telegram}),
    do: {:error, "bots.telegram must be a map"}

  defp validate_bot_names(bots) when is_map(bots), do: {:ok, %{}}
  defp validate_bot_names(_bots), do: {:error, "bots must be a map"}

  defp valid_hook_name(name) when is_binary(name) do
    if String.trim(name) == "", do: nil, else: name
  end

  defp valid_hook_name(_name), do: nil

  defp validated_string_map(entries, normalize_key, invalid_key_error, invalid_value_error) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key = normalize_key.(key)
      value = trimmed_string(value)

      cond do
        is_nil(normalized_key) or normalized_key == "" ->
          {:halt, {:error, invalid_key_error}}

        is_nil(value) ->
          {:halt, {:error, invalid_value_error.(normalized_key)}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
      end
    end)
  end

  defp trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      string -> string
    end
  end

  defp trimmed_string(_value), do: nil
end
