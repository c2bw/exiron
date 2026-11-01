defmodule Exiron.Hub.ReloadManager do
  @moduledoc false

  alias Exiron.Hub.{Boot, ClientSessions}
  alias Exiron.Telemetry

  def reload(state, action, opts) do
    started_at = System.monotonic_time()
    result = do_reload(state, action, opts)

    Telemetry.reload(
      System.monotonic_time() - started_at,
      action,
      reload_outcome(result)
    )

    result
  end

  defp do_reload(state, :reload_routes, opts) do
    with {:ok, config} <- Boot.configured_hub(opts) do
      state =
        state
        |> ClientSessions.reconcile_router(state.router, config.router)
        |> Map.put(:router, config.router)
        |> Map.put(:configuration_digest, nil)
        |> Map.put(:configuration_activated_at, nil)

      {:ok, state}
    end
  end

  defp do_reload(state, :reload_bots, opts) do
    with {:ok, config} <- Boot.configured_hub(opts),
         {:ok, state} <- Boot.reload_telegram_state(state, config, opts) do
      {:ok, %{state | configuration_digest: nil, configuration_activated_at: nil}}
    end
  end

  defp do_reload(state, :reload_configuration, opts) do
    with {:ok, config} <- Boot.configured_hub(opts),
         candidate = Map.put(state, :router, config.router),
         {:ok, candidate} <- Boot.reload_telegram_state(candidate, config, opts) do
      candidate = ClientSessions.reconcile_router(candidate, state.router, config.router)

      :ok =
        Exiron.Hub.ConfigurationHistory.checkpoint_active(
          Keyword.fetch!(opts, :config_path),
          config.source
        )

      {:ok,
       %{
         candidate
         | configuration_digest: config.source_digest,
           configuration_activated_at: DateTime.utc_now(),
           configuration_reload_failed?: false
       }}
    end
  end

  defp reload_outcome({:ok, _state}), do: :ok
  defp reload_outcome({:error, _reason}), do: :error
end
