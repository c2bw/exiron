defmodule Exiron.Hub.BotName do
  @moduledoc false

  def normalize(bot_name) when is_binary(bot_name) do
    bot_name
    |> String.trim()
    |> String.trim_leading("@")
  end

  def normalize(_bot_name), do: nil
end
