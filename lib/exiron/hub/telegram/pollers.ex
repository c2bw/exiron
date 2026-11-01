defmodule Exiron.Hub.Telegram.Pollers do
  @moduledoc false

  alias Exiron.Hub.PollerRegistry
  alias Exiron.Hub.Telegram.Poller
  alias Exiron.Secret

  def start(bots, enabled?), do: start(bots, enabled?, [])

  def start(_bots, false, _opts), do: :ok

  def start(bots, true, opts) do
    start_bots(bots, opts, [])
  end

  def stop, do: stop([])

  def stop(opts) do
    supervisor = supervisor(opts)

    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce_while(:ok, fn {_id, pid, _type, _modules}, :ok ->
      case terminate_child(supervisor, pid, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:stop_failed, pid, reason}}}
      end
    end)
  end

  def reconcile(bots, enabled?, pollers, opts \\ []) when is_list(bots) and is_map(pollers) do
    desired =
      if enabled? do
        Map.new(bots, &{&1.token, &1})
      else
        %{}
      end

    current = Map.keys(pollers) |> MapSet.new()
    desired_keys = Map.keys(desired) |> MapSet.new()

    additions = desired_keys |> MapSet.difference(current) |> MapSet.to_list()

    updates =
      desired_keys
      |> MapSet.intersection(current)
      |> Enum.filter(fn token ->
        current_name = pollers |> PollerRegistry.entry(token) |> Map.get(:bot_name)
        current_name != Map.get(Map.fetch!(desired, token), :name)
      end)

    removals = current |> MapSet.difference(desired_keys) |> MapSet.to_list()

    operations =
      Enum.map(additions, &{:start, Map.fetch!(desired, &1)}) ++
        Enum.map(updates, &{:update_name, Map.fetch!(desired, &1)}) ++
        Enum.map(removals, &{:stop, &1})

    case apply_operations(operations, pollers, [], desired, opts) do
      {:ok, _pollers} = result ->
        if enabled? do
          result
        else
          case stop(opts) do
            :ok -> result
            {:error, reason} -> {:error, reason}
          end
        end

      result ->
        result
    end
  end

  def put_bot_name(token, bot_name) when is_binary(token) do
    each(fn pid -> Poller.put_bot_name(pid, token, bot_name) end)
    :ok
  end

  def put_bot_name(pollers, token, bot_name)
      when is_map(pollers) and is_binary(token) do
    case PollerRegistry.entry(pollers, token) do
      %{pid: pid} -> Poller.put_bot_name(pid, token, bot_name)
      _missing -> :ok
    end
  end

  defp apply_operations([], pollers, _undo, _desired, _opts), do: {:ok, pollers}

  defp apply_operations([operation | rest], pollers, undo, desired, opts) do
    case apply_operation(operation, pollers, desired, opts) do
      {:ok, pollers, undo_operation} ->
        apply_operations(rest, pollers, [undo_operation | undo], desired, opts)

      {:error, reason} ->
        rollback(undo, pollers, reason, opts)
    end
  end

  defp start_bots([], _opts, _started), do: :ok

  defp start_bots([bot | rest], opts, started) do
    case start_bot(bot, opts) do
      {:ok, pid} ->
        start_bots(rest, opts, [pid | started])

      {:error, reason} ->
        rollback_started(started, opts, {:start_failed, bot_reference(bot), reason})
    end
  end

  defp rollback_started([], _opts, reason), do: {:error, reason}

  defp rollback_started([pid | rest], opts, reason) do
    case terminate_child(supervisor(opts), pid, opts) do
      :ok ->
        rollback_started(rest, opts, reason)

      {:error, rollback_reason} ->
        {:error, {:reconcile_failed, reason, {:rollback_failed, rollback_reason}}}
    end
  end

  defp apply_operation({:start, bot}, pollers, _desired, opts) do
    case start_bot(bot, opts) do
      {:ok, pid} ->
        pollers = PollerRegistry.register(pollers, bot.token, pid, bot.name)

        undo = fn pollers ->
          with :ok <- terminate_child(supervisor(opts), pid, opts) do
            {:ok, PollerRegistry.unregister(pollers, bot.token, pid)}
          end
        end

        {:ok, pollers, undo}

      {:error, reason} ->
        {:error, {:start_failed, bot_reference(bot), reason}}
    end
  end

  defp apply_operation({:update_name, bot}, pollers, _desired, _opts) do
    case PollerRegistry.entry(pollers, bot.token) do
      %{pid: pid} = entry ->
        old_name = Map.get(entry, :bot_name)
        Poller.put_bot_name(pid, bot.token, bot.name)
        pollers = PollerRegistry.update_name(pollers, bot.token, bot.name)

        undo = fn pollers ->
          Poller.put_bot_name(pid, bot.token, old_name)
          {:ok, PollerRegistry.update_name(pollers, bot.token, old_name)}
        end

        {:ok, pollers, undo}

      _missing ->
        {:error, {:update_failed, bot_reference(bot), :poller_not_registered}}
    end
  end

  defp apply_operation({:stop, token}, pollers, desired, opts) do
    case PollerRegistry.entry(pollers, token) do
      %{pid: pid} = entry ->
        bot_reference = bot_reference(token, Map.get(entry, :bot_name))

        case terminate_child(supervisor(opts), pid, opts) do
          :ok ->
            pollers = PollerRegistry.unregister(pollers, token, pid)
            bot = %{token: token, name: Map.get(entry, :bot_name)}

            undo = fn pollers ->
              case start_bot(Map.get(desired, token, bot), opts) do
                {:ok, replacement_pid} ->
                  {:ok,
                   PollerRegistry.register(
                     pollers,
                     token,
                     replacement_pid,
                     bot.name
                   )}

                {:error, reason} ->
                  {:error, {:restart_failed, bot_reference, reason}}
              end
            end

            {:ok, pollers, undo}

          {:error, reason} ->
            {:error, {:stop_failed, bot_reference, reason}}
        end

      _missing ->
        {:error, {:stop_failed, bot_reference(token, nil), :poller_not_registered}}
    end
  end

  defp rollback([], _pollers, reason, _opts), do: {:error, reason}

  defp rollback([undo | rest], pollers, reason, opts) do
    case undo.(pollers) do
      {:ok, pollers} ->
        rollback(rest, pollers, reason, opts)

      {:error, rollback_reason} ->
        {:error, {:reconcile_failed, reason, {:rollback_failed, rollback_reason}}}
    end
  end

  defp start_bot(bot, opts) do
    spec = {Poller, poller_opts(bot, opts)}
    starter = Keyword.get(opts, :start_child)

    try do
      case starter do
        fun when is_function(fun, 3) -> fun.(supervisor(opts), bot, spec)
        fun when is_function(fun, 2) -> fun.(supervisor(opts), spec)
        _missing -> DynamicSupervisor.start_child(supervisor(opts), spec)
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp terminate_child(supervisor, pid, opts) do
    stopper = Keyword.get(opts, :terminate_child)

    try do
      result =
        case stopper do
          fun when is_function(fun, 3) -> fun.(supervisor, pid, opts)
          fun when is_function(fun, 2) -> fun.(supervisor, pid)
          _missing -> DynamicSupervisor.terminate_child(supervisor, pid)
        end

      case result do
        {:error, :not_found} -> :ok
        other -> other
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp poller_opts(bot, opts) do
    configured = Keyword.get(opts, :poller_options, [])

    poller_options =
      cond do
        is_function(configured, 1) -> configured.(bot)
        is_list(configured) -> configured
        true -> []
      end

    Keyword.merge(poller_options, token: Secret.new(bot.token), bot_name: bot.name)
  end

  defp bot_reference(%{token: token} = bot) do
    bot_reference(token, Map.get(bot, :name))
  end

  defp bot_reference(token, bot_name) when is_binary(token) do
    fingerprint =
      token
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
      |> then(&("sha256:" <> &1))

    %{bot_name: bot_name, token_fingerprint: fingerprint}
  end

  defp supervisor(opts), do: Keyword.get(opts, :supervisor, Exiron.Hub.TelegramSupervisor)

  defp each(fun) do
    Exiron.Hub.TelegramSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} -> fun.(pid) end)
  end
end
