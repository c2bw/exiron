defmodule Exiron.MixProject do
  use Mix.Project

  def project do
    [
      app: :exiron,
      version: Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: [exiron: [steps: [:assemble, &Exiron.BuildInfo.write_release/1]]],
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [
        ignore_modules: [
          Inspect.Exiron.Hub.State,
          Inspect.Exiron.Hub.Telegram.BotRegistry,
          ExironWeb.SessionHTML
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Exiron.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:open_api_spex, "~> 3.21"},
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.5"},
      {:ex_gram, "~> 0.67"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind exiron", "esbuild exiron"],
      "assets.deploy": [
        "tailwind exiron --minify",
        "esbuild exiron --minify",
        "phx.digest"
      ],
      "clients.test": [
        "cmd --cd clients/elixir mix format --check-formatted --no-compile",
        "cmd --cd clients/elixir mix compile --warnings-as-errors",
        "cmd --cd clients/elixir mix test",
        "cmd elixir scripts/check_go_format.exs",
        "cmd --cd clients/go go vet -mod=readonly ./...",
        "cmd --cd clients/go go test -mod=readonly ./..."
      ],
      precommit: [
        "deps.unlock --check-unused",
        "format --check-formatted",
        "run scripts/check_versions.exs",
        "run scripts/generate_client_protocol.exs -- --check",
        "run scripts/check_contract.exs",
        "run benchmarks/hub_hot_paths.exs -- --smoke",
        "format --check-formatted benchmarks/hub_concurrent.exs benchmarks/network.exs benchmarks/support/*.ex",
        "cmd env MIX_ENV=test mix run --no-start benchmarks/hub_concurrent.exs --smoke",
        "cmd env MIX_ENV=test mix run --no-start benchmarks/network.exs --duration 4 --rate 30 --hooks 4 --media-bytes 4096 --quiet",
        "compile --warnings-as-errors",
        "test",
        "clients.test"
      ]
    ]
  end
end
