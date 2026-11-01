defmodule Exiron.ContractFixtureValidation do
  @moduledoc false

  alias OpenApiSpex.TestAssertions
  alias Exiron.Protocol
  alias ExironWeb.ApiSpec

  @contract_dir Path.expand("../../clients/contract", __DIR__)

  def http_fixture_matrix do
    Enum.map(Protocol.http_fixtures(), fn %{
                                            "file" => file,
                                            "schema" => schema,
                                            "direction" => direction
                                          } ->
      {file, schema, direction_atom(direction)}
    end)
  end

  def openapi_spec, do: ApiSpec.spec()

  def validate_http_fixture(name, schema, :response) do
    name
    |> fixture_payload()
    |> TestAssertions.assert_response_schema(schema, openapi_spec())
  end

  def validate_http_fixture(name, schema, :request) do
    name
    |> fixture_payload()
    |> TestAssertions.assert_request_schema(schema, openapi_spec())
  end

  def fixture_payload(name) do
    @contract_dir
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp direction_atom("request"), do: :request
  defp direction_atom("response"), do: :response
end
