defmodule Exiron.Hub.ManualAttachment do
  @moduledoc false
  @max_bytes 10_000_000
  def max_bytes, do: @max_bytes

  def validate(type, %{data: data, file_name: name})
      when type in ["image", "file"] and is_binary(data) and is_binary(name) do
    mime =
      if type == "image",
        do: Exiron.Hub.EventImage.mime_type(data),
        else: "application/octet-stream"

    if byte_size(data) in 1..@max_bytes and String.valid?(name) and byte_size(name) in 1..255 and
         name not in [".", ".."] and not String.contains?(name, ["\0", "\r", "\n", "/", "\\"]) and
         (type == "file" or mime in ["image/png", "image/jpeg"]) do
      {:ok, %{data: data, file_name: name, mime_type: mime, bytes: byte_size(data)}}
    else
      {:error, :invalid_attachment}
    end
  end

  def validate(_, _), do: {:error, :invalid_attachment}
end
