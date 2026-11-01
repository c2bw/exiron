defmodule Exiron.Hub.RouteConfigurationTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ConfigurationService, RouteConfiguration}
  alias Exiron.Hub.RouteConfiguration.ConflictError
  alias Exiron.Support.TempPath

  test "missing config file loads an empty route configuration" do
    path = temp_config_path()

    assert {:ok,
            %RouteConfiguration{
              path: ^path,
              version: "1",
              source: "version: \"1\"\n",
              aliases: %{},
              bots: [],
              routes: [],
              middlewares: [],
              hooks: [],
              resolved_routes: []
            }} = RouteConfiguration.load(path)
  end

  test "save replaces an existing config without leaving temporary files behind" do
    path = temp_config_path()
    original_source = config_source("ai-token")
    File.write!(path, original_source)

    source = config_source("new-token")

    assert :ok = ConfigurationService.save(path, source)
    assert File.read!(path) == source
    assert [] = Path.wildcard(Path.join(Path.dirname(path), ".#{Path.basename(path)}.*.tmp"))
  end

  test "save removes the temporary file when final replacement fails" do
    path = temp_config_path()
    File.mkdir!(path)

    assert {:error, _reason} = ConfigurationService.save(path, config_source("new-token"))
    assert [] = Path.wildcard(Path.join(Path.dirname(path), ".#{Path.basename(path)}.*.tmp"))
  end

  test "save rejects a stale expected source" do
    path = temp_config_path()
    original_source = config_source("ai-token")
    changed_source = config_source("changed-token")
    File.write!(path, original_source)
    File.write!(path, changed_source)

    assert {:error, %ConflictError{path: ^path}} =
             ConfigurationService.save(path, config_source("new-token"),
               expected_source: original_source
             )

    assert File.read!(path) == changed_source
  end

  test "concurrent saves from one revision allow only one writer" do
    path = temp_config_path()
    original_source = config_source("ai-token")
    File.write!(path, original_source)

    results =
      ["first-token", "second-token"]
      |> Task.async_stream(
        fn token ->
          ConfigurationService.save(path, config_source(token), expected_source: original_source)
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:error, %ConflictError{}}, &1)) == 1
  end

  if match?({:unix, _name}, :os.type()) do
    test "save creates new configuration files with owner-only permissions" do
      path = temp_config_path()

      assert :ok = ConfigurationService.save(path, config_source("new-token"))
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "save preserves restrictive permissions" do
      path = temp_config_path()
      File.write!(path, config_source("ai-token"))
      File.chmod!(path, 0o600)

      assert :ok = ConfigurationService.save(path, config_source("new-token"))
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end
  end

  defp config_source(token) do
    """
    version: "1"
    telegram:
      bots:
        - token: bot-token
          chats:
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
      assistant: "#{Exiron.Hub.HookToken.hash(token)}"
    """
  end

  defp temp_config_path do
    TempPath.tmp_path("route-config")
  end
end
