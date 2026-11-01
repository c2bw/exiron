defmodule ExironClient.Message do
  @moduledoc """
  Message received from an Exiron server.

  The `data` field is decoded binary data. For text payloads, it is the message
  text. For callbacks, it is the application button data. For file-like payloads,
  it is the raw file bytes.
  """

  alias ExironClient.{Error, Wire}

  @type t :: %__MODULE__{
          message_thread_id: integer() | nil,
          media_group_id: String.t() | nil,
          caption: String.t() | nil,
          entities: [map()] | nil,
          caption_entities: [map()] | nil,
          file_name: String.t() | nil,
          mime_type: String.t() | nil,
          callback_query: map() | nil,
          followup_req_id: String.t() | nil,
          media_items: [ExironClient.MediaItem.t()],
          msgtype: String.t(),
          req_id: String.t() | nil,
          message_id: integer() | nil,
          reply_to_message_id: integer() | nil,
          from: map() | nil,
          service_id: integer() | nil,
          chat_id: integer() | nil,
          instance: String.t() | nil,
          datatype: String.t(),
          sticker_id: String.t() | nil,
          sticker_emoji: String.t() | nil,
          emoji_list: [String.t()],
          data: binary()
        }

  defstruct [
    :msgtype,
    :req_id,
    :message_id,
    :reply_to_message_id,
    :from,
    :service_id,
    :chat_id,
    :instance,
    :datatype,
    :sticker_id,
    :sticker_emoji,
    :emoji_list,
    :data,
    :message_thread_id,
    :media_group_id,
    :caption,
    :entities,
    :caption_entities,
    :file_name,
    :mime_type,
    :callback_query,
    :followup_req_id,
    media_items: []
  ]

  @doc false
  @spec from_server(map(), atom()) :: {:ok, t()} | {:error, Error.t()}
  def from_server(params, fallback_type), do: Wire.Message.decode(params, fallback_type)

  @doc false
  @spec from_server_list([map()], atom()) :: {:ok, [t()]} | {:error, Error.t()}
  def from_server_list(messages, fallback_type),
    do: Wire.Message.decode_list(messages, fallback_type)

  @doc """
  Returns text data for text messages, otherwise an empty string.
  """
  @spec text(t()) :: binary()
  def text(%__MODULE__{datatype: "text", data: data}), do: data
  def text(%__MODULE__{}), do: ""

  @doc "Returns the application callback data for a button click."
  def callback_data(%__MODULE__{datatype: "callback", data: data}), do: data
  def callback_data(%__MODULE__{}), do: nil
end
