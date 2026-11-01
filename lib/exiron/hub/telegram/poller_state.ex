defmodule Exiron.Hub.Telegram.PollerState do
  @moduledoc false

  @derive {Inspect, only: [:bot_name, :offset, :max_download_bytes, :empty_poll_delay]}
  defstruct [
    :token,
    :bot_name,
    :offset,
    :get_updates,
    :get_file,
    :http_get,
    :max_download_bytes,
    :empty_poll_delay,
    answer_callback: &Exiron.Hub.Telegram.CallbackAnswer.answer/3,
    processed_callbacks: MapSet.new(),
    group_albums: false,
    album_updates: [],
    album_started_at: nil,
    album_updated_at: nil
  ]
end
