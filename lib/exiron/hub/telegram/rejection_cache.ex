defmodule Exiron.Hub.Telegram.RejectionCache do
  @moduledoc false
  defstruct entries: %{},
            cooldown_ms: 60_000,
            limit: 1000,
            suppressed: 0,
            rejections: 0,
            probes: 0,
            recoveries: 0,
            last_recovery: nil

  def check(cache, key, chat, now) do
    entries =
      [Map.get(cache.entries, {:token, key}), Map.get(cache.entries, {:chat, key, chat})]
      |> Enum.reject(&is_nil/1)

    entry = Enum.find(entries, &(&1.until > now)) || List.first(entries)

    cond do
      is_nil(entry) -> {:ok, cache}
      entry.until > now -> {:blocked, entry.code, %{cache | suppressed: cache.suppressed + 1}}
      true -> {:ok, %{cache | probes: cache.probes + 1}}
    end
  end

  def record(cache, key, chat, name, {:error, %ExGram.Error{code: code}}, now)
      when code == 401 or (code == 403 and not is_nil(chat)) do
    scope = if code == 401, do: {:token, key}, else: {:chat, key, chat}
    previous = Map.get(cache.entries, scope)

    entry = %{
      id: if(previous, do: previous.id, else: Exiron.Hub.Identifier.new()),
      code: code,
      scope: if(code == 401, do: "token", else: "chat"),
      chat_id: if(code == 403, do: chat),
      bot_name: name,
      until: now + cache.cooldown_ms,
      retry_at: DateTime.add(DateTime.utc_now(), cache.cooldown_ms, :millisecond)
    }

    entries = Map.put(cache.entries, scope, entry)

    entries =
      if map_size(entries) > cache.limit do
        {oldest, _} = Enum.min_by(entries, fn {_, entry} -> entry.until end)
        Map.delete(entries, oldest)
      else
        entries
      end

    %{cache | entries: entries, rejections: cache.rejections + 1}
  end

  def record(cache, key, chat, _name, result, now) do
    scopes = [{:token, key}, {:chat, key, chat}]

    expired =
      Enum.filter(scopes, fn scope ->
        case Map.get(cache.entries, scope) do
          %{until: until} -> until <= now
          _ -> false
        end
      end)

    recovered = result == :ok or match?({:ok, _}, result)
    count = if recovered, do: length(expired), else: 0

    last =
      if count > 0 do
        entry = Map.fetch!(cache.entries, hd(expired))
        %{bot_name: entry.bot_name, chat_id: entry.chat_id, at: DateTime.utc_now()}
      else
        cache.last_recovery
      end

    # An uncertain probe never confirms recovery or manufactures a new rejection.
    %{
      cache
      | entries: Map.drop(cache.entries, expired),
        recoveries: cache.recoveries + count,
        last_recovery: last
    }
  end

  def snapshot(cache, now) do
    records =
      cache.entries
      |> Map.values()
      |> Enum.sort_by(& &1.until, :desc)
      |> Enum.take(50)
      |> Enum.map(fn entry ->
        entry
        |> Map.delete(:until)
        |> Map.put(:phase, if(entry.until > now, do: "cooldown", else: "ready"))
      end)

    %{
      available: true,
      active: Enum.count(cache.entries, fn {_, entry} -> entry.until > now end),
      suppressed_attempts: cache.suppressed,
      rejections: cache.rejections,
      probes: cache.probes,
      recoveries: cache.recoveries,
      last_recovery: cache.last_recovery,
      records: records
    }
  end
end
