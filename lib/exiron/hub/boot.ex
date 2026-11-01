defmodule Exiron.Hub.Boot do
  @moduledoc false

  alias Exiron.Hub.{
    BotIdentity,
    BotMemberships,
    Configuration,
    EventLog,
    LookupState,
    Settings,
    Telegram
  }

  alias Exiron.Hub.Telegram.{BotRegistry, Pollers}

  alias Exiron.RuntimeConfig

  def configure_attrs(router, telegram, opts \\ Application.get_env(:exiron, :hub, [])) do
    runtime_attrs(router, telegram, opts)
  end

  def boot(opts) do
    with {:ok, config} <- configured_hub(opts),
         router = config.router,
         telegram = Telegram.new(config.telegram),
         :ok <- Telegram.start_pollers(telegram, configured_telegram_pollers_enabled?(opts)) do
      :ok =
        Exiron.Hub.ConfigurationHistory.checkpoint_active(
          Keyword.fetch!(opts, :config_path),
          config.source
        )

      state =
        runtime_attrs(router, telegram, opts)
        |> Map.merge(%{
          configuration_digest: config.source_digest,
          configuration_activated_at: DateTime.utc_now()
        })

      {:ok, BotIdentity.start_lookups(state, opts)}
    end
  end

  def configured_hub(opts \\ Application.get_env(:exiron, :hub, [])) do
    opts
    |> Keyword.fetch!(:config_path)
    |> Configuration.read()
  end

  def reload_telegram_state(state, config, opts) do
    telegram = Telegram.new(config.telegram)
    telegram_pollers_enabled? = configured_telegram_pollers_enabled?(opts)

    with {:ok, pollers} <-
           Pollers.reconcile(
             BotRegistry.poller_bots(telegram.bots),
             telegram_pollers_enabled?,
             state.telegram_pollers
           ) do
      state =
        runtime_attrs(
          state.router,
          %{telegram | poller_bot_name_updater: &Pollers.put_bot_name(pollers, &1, &2)},
          opts
        )
        |> Map.put(:telegram_pollers, pollers)
        |> then(&struct(state, &1))
        |> BotMemberships.prune_unconfigured()
        |> EventLog.enforce_limits()

      {:ok, BotIdentity.start_lookups(state, opts)}
    end
  end

  def configured_telegram_pollers_enabled?(opts) do
    RuntimeConfig.configured(opts, :telegram_pollers_enabled)
  end

  defp runtime_attrs(router, telegram, opts) do
    %{
      enabled?: true,
      telegram_pollers_enabled?: configured_telegram_pollers_enabled?(opts),
      telegram_pollers: %{},
      router: router,
      telegram: telegram,
      runtime_options: opts,
      lookups: %LookupState{generation: make_ref()},
      settings: Settings.from_options(opts)
    }
  end
end
