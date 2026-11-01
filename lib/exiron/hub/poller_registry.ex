defmodule Exiron.Hub.PollerRegistry do
  @moduledoc false

  def clear_monitors(state) do
    Enum.each(state.telegram_pollers, fn {_token, poller} -> demonitor(poller) end)
    :ok
  end

  def track(state, token, pid) when is_binary(token) and is_pid(pid),
    do: track(state, token, pid, :preserve_name)

  def track(state, token, pid, bot_name) when is_binary(token) and is_pid(pid) do
    pollers = register(state.telegram_pollers, token, pid, bot_name)
    %{state | telegram_pollers: pollers}
  end

  def track(state, _token, _pid, _bot_name), do: state

  def register(pollers, token, pid, bot_name)
      when is_map(pollers) and is_binary(token) and is_pid(pid) do
    case Map.get(pollers, token) do
      %{pid: ^pid} ->
        current = Map.get(pollers, token)
        bot_name = if bot_name == :preserve_name, do: Map.get(current, :bot_name), else: bot_name
        poller = Map.put(current, :bot_name, bot_name)
        Map.put(pollers, token, ensure_monitor(poller, pid))

      current ->
        demonitor(current)

        Map.put(pollers, token, %{
          pid: pid,
          monitor: Process.monitor(pid),
          bot_name: if(bot_name == :preserve_name, do: nil, else: bot_name)
        })
    end
  end

  def register(pollers, _token, _pid, _bot_name), do: pollers

  def unregister(pollers, token, pid) when is_map(pollers) and is_binary(token) and is_pid(pid) do
    case Map.get(pollers, token) do
      %{pid: ^pid} = poller ->
        demonitor(poller)
        Map.delete(pollers, token)

      _poller ->
        pollers
    end
  end

  def unregister(pollers, _token, _pid), do: pollers

  def update_name(pollers, token, bot_name) when is_map(pollers) and is_binary(token) do
    case Map.get(pollers, token) do
      nil -> pollers
      poller -> Map.put(pollers, token, Map.put(poller, :bot_name, bot_name))
    end
  end

  def update_name(pollers, _token, _bot_name), do: pollers

  def entry(pollers, token) when is_map(pollers) and is_binary(token),
    do: Map.get(pollers, token)

  def untrack(state, token, pid) do
    %{state | telegram_pollers: unregister(state.telegram_pollers, token, pid)}
  end

  def remove_down(state, monitor, pid) do
    case token_for_monitor(state.telegram_pollers, monitor, pid) do
      nil ->
        {:unchanged, state}

      token ->
        {:removed,
         %{
           state
           | telegram_pollers: Map.delete(state.telegram_pollers, token)
         }}
    end
  end

  defp token_for_monitor(pollers, monitor, pid) do
    Enum.find_value(pollers, fn
      {token, %{pid: ^pid, monitor: ^monitor}} -> token
      _poller -> nil
    end)
  end

  defp demonitor(%{monitor: monitor}) when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp demonitor(_poller), do: :ok

  defp ensure_monitor(%{monitor: monitor} = poller, _pid) when is_reference(monitor),
    do: poller

  defp ensure_monitor(poller, pid), do: Map.put(poller, :monitor, Process.monitor(pid))
end
