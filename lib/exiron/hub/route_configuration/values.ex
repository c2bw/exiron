defmodule Exiron.Hub.RouteConfiguration.Values do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.ValidationError

  def map_or_empty(value) when is_map(value), do: value
  def map_or_empty(_value), do: %{}

  def list_or_empty(value) when is_list(value), do: value
  def list_or_empty(_value), do: []

  def optional_string(value) do
    case trimmed_string(value) do
      "" -> nil
      string -> string
    end
  end

  def trimmed_string(nil), do: ""
  def trimmed_string(value) when is_binary(value), do: String.trim(value)

  def trimmed_string(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  def trimmed_string(_value), do: ""

  def get(attributes, key) when is_map(attributes) and is_binary(key) do
    atom_key = key_to_atom(key)

    cond do
      Map.has_key?(attributes, key) -> Map.get(attributes, key)
      atom_key && Map.has_key?(attributes, atom_key) -> Map.get(attributes, atom_key)
      true -> nil
    end
  end

  def get(_attributes, _key), do: nil

  def required_string(value, message) do
    case trimmed_string(value) do
      "" -> {:error, message}
      string -> {:ok, string}
    end
  end

  def chat_id(value) do
    case Integer.parse(trimmed_string(value)) do
      {chat_id, ""} -> {:ok, chat_id}
      _error -> {:error, "chat ID must be an integer"}
    end
  end

  def csv_list(value) do
    value
    |> trimmed_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def truthy?(value), do: value in [true, "true", "on", "1", 1]

  def validate(fields) when is_list(fields) do
    {values, errors} =
      Enum.reduce(fields, {%{}, []}, fn {field, result}, {values, errors} ->
        case result do
          {:ok, value} -> {Map.put(values, field, value), errors}
          {:error, message} -> {values, [{field, message} | errors]}
        end
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, values}
      errors -> {:error, ValidationError.new(errors)}
    end
  end

  def invalid_attributes, do: validate(base: {:error, "attributes must be a map"})

  def route_middleware(route) do
    route
    |> map_or_empty()
    |> Map.get("middleware")
    |> list_or_empty()
  end

  def route_push(route) do
    route
    |> map_or_empty()
    |> Map.get("push", false)
    |> truthy?()
  end

  def route_default_bot(route) do
    route
    |> map_or_empty()
    |> Map.get("default_bot")
    |> optional_string()
  end

  def middleware_messages(requirements) do
    requirements
    |> map_or_empty()
    |> Map.get("messages")
    |> list_or_empty()
  end

  def middleware_passthrough(requirements) do
    requirements
    |> map_or_empty()
    |> Map.get("passthrough", false)
    |> truthy?()
  end

  defp key_to_atom("bot_token"), do: :bot_token
  defp key_to_atom("bot_name"), do: :bot_name
  defp key_to_atom("chat_id"), do: :chat_id
  defp key_to_atom("alias"), do: :alias
  defp key_to_atom("middleware"), do: :middleware
  defp key_to_atom("push"), do: :push
  defp key_to_atom("hook"), do: :hook
  defp key_to_atom("messages"), do: :messages
  defp key_to_atom("passthrough"), do: :passthrough
  defp key_to_atom("token"), do: :token
  defp key_to_atom(_key), do: nil
end
