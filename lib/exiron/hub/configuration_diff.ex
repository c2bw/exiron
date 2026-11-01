defmodule Exiron.Hub.ConfigurationDiff do
  @moduledoc false
  @secret_key ~r/token|password|secret|credential|authorization|api[_-]?key/i
  @max_lines 500

  def preview(before_source, after_source) do
    with {:ok, after_map} <- decode(after_source) do
      {before_map, note} =
        case decode(before_source) do
          {:ok, map} -> {map, nil}
          :error -> {%{}, "Current source cannot be parsed; showing only the redacted target."}
        end

      secrets = Enum.uniq(secret_values(before_map) ++ secret_values(after_map))
      before_text = before_map |> redact(after_map, false, :before) |> encode(secrets)
      after_text = after_map |> redact(before_map, false, :after) |> encode(secrets)

      lines =
        List.myers_difference(String.split(before_text, "\n"), String.split(after_text, "\n"))
        |> Enum.flat_map(&context_lines/1)

      {:ok,
       %{
         changed?: before_source != after_source,
         semantic_changed?: before_map != after_map,
         note: note,
         truncated?: length(lines) > @max_lines,
         lines:
           lines
           |> Enum.take(@max_lines)
           |> Enum.with_index()
           |> Enum.map(fn {line, i} -> Map.put(line, :id, to_string(i)) end)
       }}
    else
      _ -> {:error, "The proposed configuration cannot be previewed safely."}
    end
  rescue
    _ -> {:error, "The proposed configuration cannot be previewed safely."}
  end

  defp context_lines({:eq, lines}) when length(lines) > 12 do
    Enum.map(Enum.take(lines, 4), &%{kind: :eq, text: &1}) ++
      [%{kind: :eq, text: "… #{length(lines) - 8} unchanged lines …"}] ++
      Enum.map(Enum.take(lines, -4), &%{kind: :eq, text: &1})
  end

  defp context_lines({kind, lines}), do: Enum.map(lines, &%{kind: kind, text: &1})

  defp decode(source) do
    if String.valid?(source) do
      case YamlElixir.read_from_string(source) do
        {:ok, map} when is_map(map) -> {:ok, map}
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp sensitive?(key), do: is_binary(key) and (key == "hooks" or Regex.match?(@secret_key, key))

  defp redact(value, other, sensitive, side) when is_map(value) do
    other = if is_map(other), do: other, else: %{}

    Map.new(value, fn {key, item} ->
      {key, redact(item, Map.get(other, key), sensitive or sensitive?(key), side)}
    end)
  end

  defp redact(value, other, sensitive, side) when is_list(value) do
    other = if is_list(other), do: other, else: []

    value
    |> Enum.with_index()
    |> Enum.map(fn {item, i} -> redact(item, Enum.at(other, i), sensitive, side) end)
  end

  defp redact(value, other, true, side) do
    if value == other, do: "[REDACTED: unchanged]", else: "[REDACTED: #{side}]"
  end

  defp redact(value, _other, false, _side), do: value

  defp secret_values(value, sensitive \\ false)

  defp secret_values(value, sensitive) when is_map(value),
    do:
      Enum.flat_map(value, fn {key, item} -> secret_values(item, sensitive or sensitive?(key)) end)

  defp secret_values(value, sensitive) when is_list(value),
    do: Enum.flat_map(value, &secret_values(&1, sensitive))

  defp secret_values(value, true) when is_binary(value) and value != "", do: [value]
  defp secret_values(_value, _sensitive), do: []

  defp encode(value, secrets) do
    text = value |> ordered() |> Jason.encode!(pretty: true)

    Enum.reduce(secrets, text, fn secret, text ->
      # Cover a credential reused in a non-sensitive field as well. JSON strings
      # may escape characters, so redact its encoded representation too.
      quoted = Jason.encode!(secret)
      encoded = binary_part(quoted, 1, byte_size(quoted) - 2)
      text |> String.replace(secret, "[REDACTED]") |> String.replace(encoded, "[REDACTED]")
    end)
  end

  defp ordered(value) when is_map(value),
    do:
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
      |> Jason.OrderedObject.new()

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value
end
