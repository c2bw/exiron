defmodule Exiron.ContractCheck do
  alias OpenApiSpex.TestAssertions

  @contract_dir Path.expand("../clients/contract", __DIR__)

  def run do
    manifest = Exiron.Protocol.manifest()
    validate_manifest!(manifest)

    requirements = Exiron.Protocol.fixture_requirements()
    required_files = fixture_files(requirements)
    actual_files = contract_files()

    assert_equal!(actual_files, required_files, "contract fixture list")

    validate_http_fixtures!(requirements["http"])
    validate_websocket_fixtures!(requirements["websocket"], manifest)

    scenarios = Exiron.Protocol.scenarios()
    validate_scenarios!(scenarios, manifest, requirements)
    lifecycle_cases = validate_lifecycle!(Exiron.Protocol.lifecycle_scenarios())

    IO.puts(
      "contract manifest, #{length(actual_files)} fixtures, #{length(scenarios)} protocol scenarios, and #{lifecycle_cases} lifecycle cases are valid"
    )
  end

  defp validate_lifecycle!(catalogs) do
    assert catalogs != [], "lifecycle catalogs must not be empty"
    assert_unique_strings!(Enum.map(catalogs, & &1["id"]), "lifecycle catalog ids")

    steps =
      ~w(await_handler start_drain fail_handler await_failed_stop await_acknowledgement drain await_partial await_deadline_stop cancel_request await_drained_stop check_quarantine recover restart complete_handler)

    operations =
      ~w(failure_during_drain connection_loss_before_ack deadline_during_stream cancellation_during_stream quarantine_recovery_restart)

    counters =
      ~w(handler_calls partial_replies final_replies ack_attempts ack_commits retirements quarantined_before_recovery quarantined_after_recovery quarantined_after_restart quarantined_final)

    Enum.sum_by(catalogs, fn catalog ->
      assert_keys!(
        catalog,
        ~w(scenario_version id message partial_text reply_text recovery_text cases),
        "lifecycle catalog"
      )

      assert catalog["scenario_version"] == "1", "unsupported lifecycle catalog version"
      assert_non_empty_string!(catalog["id"], "lifecycle catalog id")

      Enum.each(
        ~w(partial_text reply_text recovery_text),
        &assert_non_empty_string!(catalog[&1], &1)
      )

      message = catalog["message"]

      assert is_map(message) and message["msgtype"] == "request" and message["datatype"] == "text",
             "lifecycle message must be a routed text request"

      assert_non_empty_string!(message["req_id"], "lifecycle request id")

      assert is_binary(message["data"]) and match?({:ok, _}, Base.decode64(message["data"])),
             "lifecycle message requires base64 data"

      cases = catalog["cases"]
      assert is_list(cases) and cases != [], "lifecycle cases must not be empty"
      assert_unique_strings!(Enum.map(cases, & &1["id"]), "lifecycle case ids")

      Enum.each(cases, fn scenario ->
        label = scenario["id"]

        assert_keys!(
          scenario,
          ~w(id transport operation handler_timeout_ms cancellation_interval_ms steps expect),
          label
        )

        assert scenario["transport"] in ~w(http websocket), "#{label}: unknown transport"
        assert scenario["operation"] in operations, "#{label}: unknown operation"

        assert is_integer(scenario["handler_timeout_ms"]) and
                 scenario["handler_timeout_ms"] in 0..5000,
               "#{label}: invalid handler timeout"

        assert is_integer(scenario["cancellation_interval_ms"]) and
                 scenario["cancellation_interval_ms"] in 100..1000,
               "#{label}: invalid cancellation interval"

        assert is_list(scenario["steps"]) and scenario["steps"] != [] and
                 Enum.all?(scenario["steps"], &(&1 in steps)),
               "#{label}: unsupported lifecycle step"

        expectation = scenario["expect"]
        assert_keys!(expectation, counters ++ ~w(outcome replies), "#{label} expectation")

        Enum.each(counters, fn key ->
          assert is_integer(expectation[key]) and expectation[key] in 0..100,
                 "#{label}: invalid #{key}"
        end)

        assert expectation["outcome"] in ~w(handler_failed deadline_exceeded drained recovered_and_restarted),
               "#{label}: invalid outcome"

        assert is_list(expectation["replies"]), "#{label}: replies must be a list"

        Enum.each(expectation["replies"], fn reply ->
          assert_keys!(reply, ~w(request_id text final), "#{label} reply")
          assert_non_empty_string!(reply["request_id"], "#{label} reply request id")
          assert_non_empty_string!(reply["text"], "#{label} reply text")
          assert is_boolean(reply["final"]), "#{label}: final must be a boolean"
        end)
      end)

      length(cases)
    end)
  end

  defp assert_keys!(value, keys, label) do
    assert is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys),
           "#{label}: missing or unknown fields"
  end

  defp validate_manifest!(manifest) do
    assert_non_empty_string!(manifest["protocol_version"], "protocol_version")
    assert_unique_strings!(manifest["capabilities"], "capabilities")
    assert_unique_strings!(manifest["datatypes"], "datatypes")

    errors = manifest["errors"]
    assert is_map(errors) and map_size(errors) > 0, "errors must be a non-empty object"

    Enum.each(errors, fn {code, descriptor} ->
      assert_non_empty_string!(code, "error code")
      assert is_integer(descriptor["status"]), "#{code} must define an integer status"
      assert_non_empty_string!(descriptor["message"], "#{code} message")
      assert_unique_strings!(descriptor["reasons"], "#{code} reasons")
    end)

    websocket = manifest["websocket"]
    assert_unique_strings!(websocket["server_frame_types"], "server frame types")
    assert_unique_strings!(websocket["client_frame_types"], "client frame types")
  end

  defp validate_http_fixtures!(fixtures) do
    spec = ExironWeb.ApiSpec.spec()

    Enum.each(fixtures, fn %{
                             "file" => file,
                             "schema" => schema,
                             "direction" => direction
                           } ->
      payload = read_fixture!(file)

      case direction do
        "request" -> TestAssertions.assert_request_schema(payload, schema, spec)
        "response" -> TestAssertions.assert_response_schema(payload, schema, spec)
        _direction -> raise "#{file} has an invalid HTTP fixture direction"
      end
    end)
  end

  defp validate_websocket_fixtures!(fixtures, manifest) do
    server_frames = manifest["websocket"]["server_frame_types"]
    client_frames = manifest["websocket"]["client_frame_types"]
    error_codes = Map.keys(manifest["errors"])

    Enum.each(fixtures, fn %{
                             "file" => file,
                             "type" => type,
                             "direction" => direction,
                             "required" => required
                           } ->
      payload = read_fixture!(file)
      expected_frames = if direction == "request", do: client_frames, else: server_frames

      assert type in expected_frames, "#{file} references an undeclared WebSocket frame type"
      assert payload["type"] == type, "#{file} has the wrong WebSocket frame type"

      Enum.each(required, fn key ->
        assert Map.has_key?(payload, key), "#{file} is missing required field #{key}"
      end)

      if type == "error" do
        assert payload["code"] in error_codes, "#{file} has an unknown error code"
      end
    end)
  end

  defp validate_scenarios!(scenarios, manifest, requirements) do
    assert is_list(scenarios) and scenarios != [], "contract scenarios must not be empty"

    scenario_ids = Enum.map(scenarios, &Map.get(&1, "id"))
    assert_unique_strings!(scenario_ids, "scenario ids")

    fixture_names = fixture_files(requirements) |> MapSet.new()
    server_frames = manifest["websocket"]["server_frame_types"]
    client_frames = manifest["websocket"]["client_frame_types"]
    error_codes = Map.keys(manifest["errors"])
    capabilities = manifest["capabilities"]

    Enum.each(scenarios, fn scenario ->
      validate_scenario!(
        scenario,
        fixture_names,
        error_codes,
        server_frames,
        client_frames,
        capabilities
      )
    end)
  end

  defp validate_scenario!(
         scenario,
         fixture_names,
         error_codes,
         server_frames,
         client_frames,
         capabilities
       ) do
    assert is_map(scenario), "scenario must be an object"
    assert scenario["scenario_version"] == "1", "scenario_version must be \"1\""
    assert_non_empty_string!(scenario["id"], "scenario id")
    assert_non_empty_string!(scenario["category"], "#{scenario["id"]} category")

    assert scenario["transport"] in ["http", "websocket"],
           "#{scenario["id"]} has an invalid transport"

    cases = scenario["cases"]
    assert is_list(cases) and cases != [], "#{scenario["id"]} cases must not be empty"
    case_ids = Enum.map(cases, &Map.get(&1, "id"))
    assert_unique_strings!(case_ids, "#{scenario["id"]} case ids")

    Enum.each(cases, fn scenario_case ->
      validate_scenario_case!(
        scenario,
        scenario_case,
        fixture_names,
        error_codes,
        server_frames,
        client_frames,
        capabilities
      )
    end)
  end

  defp validate_scenario_case!(
         scenario,
         scenario_case,
         fixture_names,
         error_codes,
         server_frames,
         client_frames,
         capabilities
       ) do
    scenario_label = "#{scenario["id"]}/#{scenario_case["id"]}"
    assert is_map(scenario_case), "#{scenario_label} must be an object"
    assert_non_empty_string!(scenario_case["id"], "#{scenario_label} id")
    assert is_map(scenario_case["request"]), "#{scenario_label} request must be an object"
    assert is_map(scenario_case["response"]), "#{scenario_label} response must be an object"

    validate_scenario_references!(
      scenario_case,
      scenario_label,
      fixture_names,
      error_codes,
      server_frames,
      client_frames,
      capabilities
    )
  end

  defp validate_scenario_references!(
         value,
         label,
         fixture_names,
         error_codes,
         server_frames,
         client_frames,
         capabilities
       )
       when is_map(value) do
    Enum.each(value, fn {key, nested_value} ->
      validate_scenario_reference!(
        key,
        nested_value,
        label,
        fixture_names,
        error_codes,
        server_frames,
        client_frames,
        capabilities
      )

      validate_scenario_references!(
        nested_value,
        label,
        fixture_names,
        error_codes,
        server_frames,
        client_frames,
        capabilities
      )
    end)
  end

  defp validate_scenario_references!(
         values,
         label,
         fixture_names,
         error_codes,
         server_frames,
         client_frames,
         capabilities
       )
       when is_list(values) do
    Enum.each(
      values,
      &validate_scenario_references!(
        &1,
        label,
        fixture_names,
        error_codes,
        server_frames,
        client_frames,
        capabilities
      )
    )
  end

  defp validate_scenario_references!(
         _value,
         _label,
         _fixture_names,
         _error_codes,
         _server_frames,
         _client_frames,
         _capabilities
       ),
       do: :ok

  defp validate_scenario_reference!(
         key,
         value,
         label,
         fixture_names,
         error_codes,
         server_frames,
         client_frames,
         capabilities
       ) do
    case key do
      "fixture" when is_binary(value) ->
        assert MapSet.member?(fixture_names, value),
               "#{label} references missing fixture #{value}"

      "request_fixture" when is_binary(value) ->
        assert MapSet.member?(fixture_names, value),
               "#{label} references missing request fixture #{value}"

      "response_fixture" when is_binary(value) ->
        assert MapSet.member?(fixture_names, value),
               "#{label} references missing response fixture #{value}"

      "frame_fixture" when is_binary(value) ->
        assert MapSet.member?(fixture_names, value),
               "#{label} references missing frame fixture #{value}"

      "error_code" when is_binary(value) ->
        assert value in error_codes, "#{label} references unknown error code #{value}"

      "frame_type" when is_binary(value) ->
        assert value in (server_frames ++ client_frames),
               "#{label} references unknown frame type #{value}"

      "server_frame_type" when is_binary(value) ->
        assert value in server_frames, "#{label} references unknown server frame type #{value}"

      "client_frame_type" when is_binary(value) ->
        assert value in client_frames, "#{label} references unknown client frame type #{value}"

      "capability" when is_binary(value) ->
        validate_capability!(value, label, capabilities)

      "capabilities" ->
        validate_capabilities!(value, label, capabilities)

      "required_capabilities" ->
        validate_capabilities!(value, label, capabilities)

      "protocol_version" when is_binary(value) ->
        assert value == "manifest", "#{label} protocol_version must use the manifest reference"

      _key ->
        :ok
    end
  end

  defp validate_capabilities!("manifest", _label, _capabilities), do: :ok

  defp validate_capabilities!(values, label, capabilities) when is_list(values) do
    Enum.each(values, &validate_capability!(&1, label, capabilities))
  end

  defp validate_capabilities!(_value, label, _capabilities),
    do: raise("#{label} capabilities must be a list or manifest")

  defp validate_capability!(value, label, capabilities) do
    assert is_binary(value) and value in capabilities,
           "#{label} references unknown capability #{value}"
  end

  defp read_fixture!(file) do
    @contract_dir
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
  rescue
    error -> raise "invalid contract fixture #{file}: #{Exception.message(error)}"
  end

  defp contract_files do
    @contract_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.reject(&(&1 == "manifest.json"))
    |> Enum.sort()
  end

  defp fixture_files(requirements) do
    (requirements["http"] ++ requirements["websocket"])
    |> Enum.map(&Map.fetch!(&1, "file"))
    |> Enum.sort()
  end

  defp assert_non_empty_string!(value, label) do
    assert is_binary(value) and value != "", "#{label} must be a non-empty string"
  end

  defp assert_unique_strings!(values, label) do
    assert is_list(values) and Enum.all?(values, &is_binary/1),
           "#{label} must be a list of strings"

    assert length(values) == length(Enum.uniq(values)), "#{label} must not contain duplicates"
  end

  defp assert_equal!(left, right, label) do
    assert left == right, "#{label} mismatch: #{inspect(left)} != #{inspect(right)}"
  end

  defp assert(condition, message) do
    unless condition, do: raise(message)
  end
end

Exiron.ContractCheck.run()
