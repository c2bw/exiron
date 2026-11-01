defmodule ExironClient.Protocol do
  @moduledoc """
  Protocol metadata advertised by an Exiron server.

  Older servers may omit these fields, in which case `version` is `nil` and
  `capabilities` is empty.
  """

  defstruct [:version, capabilities: []]

  alias ExironClient.Protocol.Generated

  @type t :: %__MODULE__{version: String.t() | nil, capabilities: [String.t()]}

  @doc "Returns the protocol version implemented by this client."
  @spec current_version() :: String.t()
  def current_version, do: Generated.version()

  @doc "Returns the capabilities defined by the current client contract."
  @spec capabilities() :: [String.t()]
  def capabilities, do: Generated.capabilities()

  @doc false
  def server_frame_type(type), do: Generated.server_frame_type(type)

  @doc false
  def client_frame_type(type), do: Generated.client_frame_type(type)

  @spec from_wire(map()) :: t()
  def from_wire(payload) when is_map(payload) do
    %__MODULE__{
      version: string(payload, "protocol_version"),
      capabilities: string_list(payload, "capabilities")
    }
  end

  @spec supports?(t(), String.t()) :: boolean()
  def supports?(%__MODULE__{capabilities: capabilities}, capability),
    do: capability in capabilities

  defp string(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp string_list(payload, key) do
    case Map.get(payload, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end
end
