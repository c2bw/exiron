defmodule Exiron.Hub.ActivityState do
  @moduledoc false

  defstruct trace_revision: 0,
            traces: %{},
            trace_order: [],
            events: [],
            send_failures: [],
            membership_events: [],
            overload_events: [],
            bot_memberships: %{},
            client_events: []

  @type t :: %__MODULE__{
          trace_revision: non_neg_integer(),
          traces: map(),
          trace_order: list(),
          events: list(),
          send_failures: list(),
          membership_events: list(),
          overload_events: list(),
          bot_memberships: map(),
          client_events: list()
        }
end
