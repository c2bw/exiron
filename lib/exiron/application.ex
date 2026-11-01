defmodule Exiron.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = ExironWeb.Plugs.TrustedProxy.validate_configuration!()
    Exiron.ReleaseMaintenance.mark_boot()

    children = [
      ExironWeb.Telemetry,
      Exiron.Metrics,
      {DNSCluster, query: Application.get_env(:exiron, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Exiron.PubSub},
      {Finch, name: Exiron.Finch, pools: %{default: [protocols: [:http1]]}},
      Exiron.Hub.EventMediaStore,
      Exiron.Hub.Supervisor,
      ExironWeb.Plugs.RateLimit.Cleaner,
      # Start to serve requests, typically the last entry
      ExironWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Exiron.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExironWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
