defmodule Exiron.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Exiron.Hub.{Boot, Settings}
  alias Exiron.RuntimeConfig

  describe "parse_boolean/2" do
    test "parses supported true and false values" do
      assert RuntimeConfig.parse_boolean(" true ", false)
      assert RuntimeConfig.parse_boolean("YES", false)
      refute RuntimeConfig.parse_boolean(" off ", true)
      refute RuntimeConfig.parse_boolean("0", true)
    end

    test "returns the default for missing and invalid values" do
      assert RuntimeConfig.parse_boolean(nil, true)
      refute RuntimeConfig.parse_boolean("maybe", false)
    end
  end

  describe "parse_positive_integer/3" do
    test "parses positive integers and uses the default when missing" do
      assert RuntimeConfig.parse_positive_integer("EXIRON_LIMIT", " 42 ", 7) == 42
      assert RuntimeConfig.parse_positive_integer("EXIRON_LIMIT", nil, 7) == 7
    end

    test "rejects zero, negative, and malformed values" do
      for value <- ["0", "-1", "1x"] do
        assert_raise RuntimeError,
                     "environment variable EXIRON_LIMIT must be a positive integer.",
                     fn ->
                       RuntimeConfig.parse_positive_integer("EXIRON_LIMIT", value, 7)
                     end
      end
    end
  end

  describe "parse_non_negative_integer/3" do
    test "accepts zero and positive integers" do
      assert RuntimeConfig.parse_non_negative_integer("EXIRON_LIMIT", "0", 7) == 0
      assert RuntimeConfig.parse_non_negative_integer("EXIRON_LIMIT", " 42 ", 7) == 42
      assert RuntimeConfig.parse_non_negative_integer("EXIRON_LIMIT", nil, 7) == 7
    end

    test "rejects negative and malformed values" do
      for value <- ["-1", "1x"] do
        assert_raise RuntimeError,
                     "environment variable EXIRON_LIMIT must be a non-negative integer.",
                     fn -> RuntimeConfig.parse_non_negative_integer("EXIRON_LIMIT", value, 7) end
      end
    end
  end

  test "schema defaults match the Hub defaults" do
    expected_defaults = %{
      client_timeout: 3_000,
      pending_timeout: 600_000,
      send_timeout: 30_000,
      max_pending: 1_000,
      max_queue_per_hook: 100,
      max_queue_bytes_per_hook: 50 * 1024 * 1024,
      max_buffered_bytes: 256 * 1024 * 1024,
      max_event_image_preview_bytes: 8 * 1024 * 1024,
      max_event_image_history_bytes: 64 * 1024 * 1024,
      max_in_flight_sends: 100,
      max_in_flight_send_bytes: 256 * 1024 * 1024,
      max_in_flight_send_bytes_per_hook: 64 * 1024 * 1024,
      max_in_flight_sends_per_hook: 10,
      telegram_pollers_enabled: true
    }

    for {setting, expected} <- expected_defaults do
      assert RuntimeConfig.default(setting) == expected
    end

    settings = Settings.from_options([])

    for key <- Settings.keys() do
      assert Settings.fetch!(settings, key) == RuntimeConfig.default(key)
    end

    assert Boot.configured_telegram_pollers_enabled?([]) ==
             RuntimeConfig.default(:telegram_pollers_enabled)
  end

  test "schema contains the preserved environment names and bounds" do
    assert RuntimeConfig.env_name(:client_timeout) == "EXIRON_CLIENT_TIMEOUT_MS"
    assert RuntimeConfig.env_name(:max_queue_bytes_per_hook) == "EXIRON_MAX_QUEUE_BYTES_PER_HOOK"
    assert RuntimeConfig.minimum(:max_event_image_preview_bytes) == 0
    assert RuntimeConfig.minimum(:max_queue_per_hook) == 1
    assert RuntimeConfig.env_name(:max_buffered_bytes) == "EXIRON_MAX_BUFFERED_BYTES"
    assert RuntimeConfig.minimum(:max_buffered_bytes) == 1
    assert RuntimeConfig.env_name(:max_in_flight_send_bytes) == "EXIRON_MAX_IN_FLIGHT_SEND_BYTES"

    assert RuntimeConfig.env_name(:max_in_flight_send_bytes_per_hook) ==
             "EXIRON_MAX_IN_FLIGHT_SEND_BYTES_PER_HOOK"
  end

  test "reads, parses, overrides, and normalizes configured values" do
    env_name = RuntimeConfig.env_name(:client_timeout)
    previous = System.get_env(env_name)
    on_exit(fn -> restore_env(env_name, previous) end)

    System.delete_env(env_name)
    refute RuntimeConfig.env_present?(:client_timeout)
    assert RuntimeConfig.from_env(:client_timeout) == 3_000
    assert RuntimeConfig.from_env(:client_timeout, 25) == 25

    System.put_env(env_name, "42")
    assert RuntimeConfig.env(:client_timeout) == "42"
    assert RuntimeConfig.env(:client_timeout, "fallback") == "42"
    assert RuntimeConfig.env_present?(:client_timeout)
    assert RuntimeConfig.from_env(:client_timeout) == 42

    assert RuntimeConfig.configured([client_timeout: 0], :client_timeout) == 1
    assert RuntimeConfig.normalize(:max_event_image_preview_bytes, -1) == 0
    assert RuntimeConfig.normalize(:enabled, false) == false
    assert RuntimeConfig.normalize(:config_path, "custom.yml") == "custom.yml"
  end

  test "non-string parser inputs use boolean defaults and reject integer values" do
    assert RuntimeConfig.parse_boolean(:invalid, true)

    assert_raise RuntimeError, fn ->
      RuntimeConfig.parse_positive_integer("EXIRON_LIMIT", 12, 7)
    end

    assert_raise RuntimeError, fn ->
      RuntimeConfig.parse_non_negative_integer("EXIRON_LIMIT", 12, 7)
    end
  end

  test "per-hook send capacity reads its environment setting and rejects invalid limits" do
    name = RuntimeConfig.env_name(:max_in_flight_sends_per_hook)
    assert name == "EXIRON_MAX_IN_FLIGHT_SENDS_PER_HOOK"
    previous = System.get_env(name)
    on_exit(fn -> restore_env(name, previous) end)
    System.put_env(name, "4")
    assert RuntimeConfig.from_env(:max_in_flight_sends_per_hook) == 4

    for value <- ["0", "-1", "bad"] do
      System.put_env(name, value)
      assert_raise RuntimeError, fn -> RuntimeConfig.from_env(:max_in_flight_sends_per_hook) end
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
