defmodule ExironClient.Auth do
  @moduledoc """
  Typed authentication response returned by Exiron.
  """

  defstruct [
    :auth_response,
    :hook,
    :msgtype,
    :server_version,
    :protocol_version,
    capabilities: [],
    extra: %{}
  ]

  @known_fields ~w(auth_response hook msgtype server_version protocol_version capabilities)

  @type t :: %__MODULE__{
          auth_response: String.t() | nil,
          hook: String.t() | nil,
          msgtype: String.t() | nil,
          server_version: String.t() | nil,
          protocol_version: String.t() | nil,
          capabilities: [String.t()],
          extra: map()
        }

  @spec from_wire(map()) :: t()
  def from_wire(%{} = response) do
    %__MODULE__{
      auth_response: response["auth_response"],
      hook: response["hook"],
      msgtype: response["msgtype"],
      server_version: response["server_version"],
      protocol_version: response["protocol_version"],
      capabilities: string_list(response["capabilities"]),
      extra: Map.drop(response, @known_fields)
    }
  end

  @doc "Returns protocol metadata advertised by the authentication response."
  @spec protocol(t()) :: ExironClient.Protocol.t()
  def protocol(%__MODULE__{} = response) do
    %ExironClient.Protocol{
      version: response.protocol_version,
      capabilities: response.capabilities
    }
  end

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []
end
