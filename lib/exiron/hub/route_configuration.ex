defmodule Exiron.Hub.RouteConfiguration do
  @moduledoc false

  alias Exiron.Hub.Configuration
  alias Exiron.Hub.RouteConfiguration.{Mutator, Projection}

  @derive {Inspect, only: [:path, :version]}
  defstruct path: nil,
            version: Configuration.schema_version(),
            source: "",
            configuration: nil,
            router: nil,
            aliases: %{},
            bots: [],
            routes: [],
            middlewares: [],
            hooks: [],
            resolved_routes: []

  @type t :: %__MODULE__{}

  def load(path) do
    case File.read(path) do
      {:ok, source} ->
        load_source(path, source)

      {:error, :enoent} ->
        load_source(path, Configuration.empty_source())

      {:error, reason} ->
        {:error, reason}
    end
  end

  def load_source(path, source) do
    with {:ok, %Configuration{} = configuration} <- Configuration.read_source(source) do
      {:ok, Projection.from_configuration(path, source, configuration)}
    end
  end

  defdelegate put_chat_route(source, attrs), to: Mutator
  defdelegate put_telegram_bot(source, attrs), to: Mutator
  defdelegate put_middleware_route(source, attrs), to: Mutator
  defdelegate put_hook(source, attrs), to: Mutator
end
