defmodule ExironClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :exiron_client,
      version: Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim(),
      package: [files: ["lib", "mix.exs", "README.md", "VERSION"]],
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7"},
      {:websockex, "~> 0.4"}
    ]
  end
end
