defmodule Exiron.Support.RouterHelper do
  @moduledoc false

  alias Exiron.Hub.Router
  alias Exiron.Support.TempPath
  import ExUnit.Assertions

  def write_router!(name, yaml) do
    path = TempPath.tmp_path(name)
    File.write!(path, yaml)
    path
  end

  def load_router!(name, yaml \\ default_router_yaml()) do
    path = write_router!(name, yaml)
    assert {:ok, router} = Router.load(path)
    router
  end

  def default_router_yaml do
    """
    aliases:
      telegram:
        home: 123
    routes:
      home:
        middleware:
          - family
    middlewares:
      family:
        routes:
          assistant:
            messages:
              - "/ai"
    hooks:
      assistant: "ai-token"
    """
  end
end
