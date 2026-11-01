defmodule Exiron.Hub.ConfigurationServiceTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.ConfigurationService
  alias Exiron.Hub.RouteConfiguration
  alias Exiron.Hub.RouteConfiguration.ConflictError
  alias Exiron.Support.TempPath

  test "reports a reload failure after the validated source is written" do
    path = temp_config_path()
    source = config_source("new-token")

    assert {:ok, %{configuration: %RouteConfiguration{}, reload: {:error, :reload_failed}}} =
             ConfigurationService.save_and_reload(path, source,
               reload: fn -> {:error, :reload_failed} end
             )

    assert File.read!(path) == source
  end

  test "preserves optimistic concurrency conflicts and does not invoke reload" do
    path = temp_config_path()
    expected_source = config_source("expected-token")
    current_source = config_source("current-token")
    File.write!(path, current_source)

    assert {:error, %ConflictError{path: ^path}} =
             ConfigurationService.save_and_reload(path, config_source("new-token"),
               expected_source: expected_source,
               reload: fn -> flunk("reload must not run after a conflict") end
             )

    assert File.read!(path) == current_source
  end

  test "preserves saved success when the Hub call exits with an unknown activation outcome" do
    path = temp_config_path()
    source = config_source("saved-token")

    assert {:ok, %{source: ^source, reload: {:error, :activation_unconfirmed}}} =
             ConfigurationService.save_and_reload(path, source, reload: fn -> exit(:timeout) end)

    assert File.read!(path) == source
  end

  test "activation retries do not write the file and reject stale source" do
    path = temp_config_path()
    source = config_source("saved-token")
    File.write!(path, source)
    assert :ok = ConfigurationService.activate_saved(path, source, reload: fn -> :ok end)
    assert File.read!(path) == source

    newer_source = config_source("newer-token")
    File.write!(path, newer_source)

    assert {:error, %ConflictError{}} =
             ConfigurationService.activate_saved(path, source,
               reload: fn -> flunk("stale activation must not run") end
             )

    assert File.read!(path) == newer_source
  end

  test "translates common configuration failures for callers" do
    assert ConfigurationService.error_message(:disabled) == "disabled"
    assert ConfigurationService.error_message("invalid YAML") == "invalid YAML"

    error = RuntimeError.exception("reload failed")
    assert ConfigurationService.error_message(error) == "reload failed"
  end

  defp config_source(token) do
    """
    version: "1"
    hooks:
      assistant: "#{Exiron.Hub.HookToken.hash(token)}"
    """
  end

  defp temp_config_path do
    TempPath.tmp_path("configuration-service")
  end
end
