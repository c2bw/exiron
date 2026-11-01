defmodule Exiron.Hub.PublicationState do
  @moduledoc false

  defstruct trace_revision: 0, revision: 0, snapshot: nil

  @type t :: %__MODULE__{
          trace_revision: non_neg_integer(),
          revision: non_neg_integer(),
          snapshot: map() | nil
        }
end
