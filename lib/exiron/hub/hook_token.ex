defmodule Exiron.Hub.HookToken do
  @moduledoc false

  alias Exiron.Hub.RouteConfiguration.{Document, Encoder}
  alias Exiron.Hub.Telegram

  @prefix "sha256:"
  @digest_pattern ~r/\Asha256:[0-9a-fA-F]{64}\z/

  @spec digest?(term()) :: boolean()
  def digest?(value) when is_binary(value) do
    Regex.match?(@digest_pattern, String.trim(value))
  end

  def digest?(_value), do: false

  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@digest_pattern, trimmed) do
      String.downcase(trimmed)
    else
      raw_digest(trimmed)
    end
  end

  @spec raw_digest(String.t()) :: String.t()
  def raw_digest(token) when is_binary(token) do
    @prefix <> (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower))
  end

  @spec matches?(term(), String.t()) :: boolean()
  def matches?(configured_value, incoming_token)
      when is_binary(configured_value) and is_binary(incoming_token) do
    matches?(configured_value, raw_digest(incoming_token), incoming_token)
  end

  def matches?(_configured_value, _incoming_token), do: false

  @spec matches?(term(), String.t(), String.t()) :: boolean()
  def matches?(configured_value, incoming_digest, incoming_token)
      when is_binary(configured_value) and is_binary(incoming_digest) and
             is_binary(incoming_token) do
    if String.starts_with?(configured_value, @prefix) do
      Plug.Crypto.secure_compare(String.downcase(configured_value), incoming_digest)
    else
      Plug.Crypto.secure_compare(configured_value, incoming_token)
    end
  end

  def matches?(_configured_value, _incoming_digest, _incoming_token), do: false

  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(value) when is_binary(value) do
    trimmed = String.trim(value)

    case String.downcase(trimmed) do
      @prefix <> hex when byte_size(hex) == 64 ->
        "#{@prefix}#{String.slice(hex, 0, 6)}...#{String.slice(hex, -4, 4)}"

      _other ->
        Telegram.token_fingerprint(trimmed)
    end
  end

  @spec normalize_source_hooks(String.t()) :: String.t()
  def normalize_source_hooks(source) when is_binary(source) do
    with {:ok, decoded} when is_map(decoded) <- YamlElixir.read_from_string(source),
         hooks when is_map(hooks) <- Map.get(decoded, "hooks"),
         true <- has_unhashed_hook?(hooks) do
      replace_source_hooks(source, decoded, hooks)
    else
      _other -> source
    end
  end

  defp has_unhashed_hook?(hooks) do
    Enum.any?(hooks, fn {name, token} ->
      valid_non_empty_string?(name) and valid_non_empty_string?(token) and not digest?(token)
    end)
  end

  defp valid_non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_non_empty_string?(_value), do: false

  defp replace_source_hooks(source, decoded, hooks) do
    rewritten = rewrite_hook_lines(source)

    case YamlElixir.read_from_string(rewritten) do
      {:ok, %{"hooks" => rewritten_hooks}} when is_map(rewritten_hooks) ->
        if has_unhashed_hook?(rewritten_hooks) do
          fallback_encode(decoded, hooks)
        else
          rewritten
        end

      _other ->
        fallback_encode(decoded, hooks)
    end
  end

  defp fallback_encode(decoded, hooks) do
    hashed_hooks =
      Map.new(hooks, fn {name, token} ->
        if valid_non_empty_string?(name) and valid_non_empty_string?(token) do
          {name, hash(token)}
        else
          {name, token}
        end
      end)

    decoded
    |> Map.put("hooks", hashed_hooks)
    |> Document.ensure_supported_sections()
    |> Encoder.encode()
  end

  defp rewrite_hook_lines(source) do
    lines = String.split(source, "\n")

    {rewritten_lines, _in_hooks?} =
      Enum.map_reduce(lines, false, fn line, in_hooks? ->
        cond do
          Regex.match?(~r/^hooks:\s*(?:#.*)?$/, line) ->
            {line, true}

          in_hooks? and Regex.match?(~r/^\s*(?:#.*)?$/, line) ->
            {line, true}

          in_hooks? and Regex.match?(~r/^[^\s#]/, line) ->
            {line, false}

          in_hooks? ->
            {rewrite_hook_line(line), true}

          true ->
            {line, false}
        end
      end)

    Enum.join(rewritten_lines, "\n")
  end

  defp rewrite_hook_line(line) do
    with {:ok, parsed} when is_map(parsed) and map_size(parsed) == 1 <-
           YamlElixir.read_from_string(String.trim(line)),
         [{name, token}] <- Map.to_list(parsed),
         true <-
           valid_non_empty_string?(to_string(name)) and valid_non_empty_string?(token) and
             not digest?(token),
         [_, prefix] <- Regex.run(~r/^(\s*(?:"[^"]+"|'[^']+'|[^:#]+?)\s*:\s*).*$/, line) do
      prefix <> inspect(hash(token))
    else
      _other -> line
    end
  end
end
