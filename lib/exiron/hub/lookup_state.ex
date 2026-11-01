defmodule Exiron.Hub.LookupState do
  @moduledoc false

  defstruct generation: nil,
            membership_keys: MapSet.new(),
            incoming_message_keys: MapSet.new(),
            incoming_message_key_order: []

  @type t :: %__MODULE__{
          generation: reference() | nil,
          membership_keys: MapSet.t(),
          incoming_message_keys: MapSet.t(),
          incoming_message_key_order: list()
        }
end
