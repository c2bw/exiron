defmodule Exiron.Hub.Telegram.AlbumBuffer do
  @moduledoc false
  @quiet_ms 350
  @max_wait_ms 1500
  @max_updates 100

  def pending?(state), do: state.album_updates != []

  def collect(state, updates, now \\ System.monotonic_time(:millisecond)) do
    if not state.group_albums or (not pending?(state) and not Enum.any?(updates, &album?/1)) do
      {:ready, updates, state}
    else
      merged =
        (state.album_updates ++ updates)
        |> Enum.uniq_by(& &1.update_id)
        |> Enum.sort_by(& &1.update_id)
        |> Enum.take(@max_updates)

      changed? = length(merged) != length(state.album_updates)
      started = state.album_started_at || now
      updated = if changed?, do: now, else: state.album_updated_at || now

      state = %{
        state
        | album_updates: merged,
          album_started_at: started,
          album_updated_at: updated
      }

      if now - updated >= @quiet_ms or now - started >= @max_wait_ms do
        {:ready, merged,
         %{state | album_updates: [], album_started_at: nil, album_updated_at: nil}}
      else
        {:buffered, state}
      end
    end
  end

  def album?(%{message: %{media_group_id: id}}) when is_binary(id) and id != "", do: true
  def album?(_), do: false
end
