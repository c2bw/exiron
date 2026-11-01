defmodule Exiron.Hub.Settings do
  @moduledoc false

  alias Exiron.RuntimeConfig

  @setting_keys [
    :client_timeout,
    :pending_timeout,
    :send_timeout,
    :max_pending,
    :max_queue_per_hook,
    :max_queue_bytes_per_hook,
    :max_buffered_bytes,
    :max_event_image_preview_bytes,
    :max_event_image_history_bytes,
    :max_in_flight_sends,
    :max_in_flight_send_bytes,
    :max_in_flight_send_bytes_per_hook,
    :max_in_flight_sends_per_hook
  ]

  @enforce_keys @setting_keys
  defstruct @setting_keys

  @type t :: %__MODULE__{
          client_timeout: pos_integer(),
          pending_timeout: pos_integer(),
          send_timeout: pos_integer(),
          max_pending: pos_integer(),
          max_queue_per_hook: pos_integer(),
          max_queue_bytes_per_hook: pos_integer(),
          max_buffered_bytes: pos_integer(),
          max_event_image_preview_bytes: non_neg_integer(),
          max_event_image_history_bytes: non_neg_integer(),
          max_in_flight_sends: pos_integer(),
          max_in_flight_send_bytes: pos_integer(),
          max_in_flight_send_bytes_per_hook: pos_integer(),
          max_in_flight_sends_per_hook: pos_integer()
        }

  @spec from_options(keyword()) :: t()
  def from_options(opts) when is_list(opts) do
    values = Map.new(@setting_keys, &{&1, RuntimeConfig.configured(opts, &1)})
    struct!(__MODULE__, values)
  end

  @spec fetch!(t(), atom()) :: term()
  def fetch!(%__MODULE__{} = settings, key) when key in @setting_keys,
    do: Map.fetch!(settings, key)

  @spec keys() :: [atom()]
  def keys, do: @setting_keys
end
