defmodule Exiron.Hub.State do
  @moduledoc false

  alias Exiron.Hub.{
    ActivityState,
    DeliveryState,
    LookupState,
    PublicationState,
    Router,
    Settings,
    Telegram
  }

  @derive {Inspect,
           only: [
             :enabled?,
             :telegram_pollers_enabled?,
             :telegram_last_polled_at,
             :settings
           ]}
  defstruct idempotency: %Exiron.Hub.Idempotency{},
            drain: %Exiron.Hub.Drain{},
            enabled?: false,
            boot_failed?: false,
            telegram_pollers_enabled?: false,
            telegram_pollers: %{},
            telegram_last_polled_at: nil,
            router: nil,
            telegram: nil,
            runtime_options: [],
            settings: Settings.from_options([]),
            delivery: %DeliveryState{},
            activity: %ActivityState{},
            health: %{},
            configuration_digest: nil,
            configuration_activated_at: nil,
            configuration_reload_failed?: false,
            lookups: %LookupState{},
            publication: %PublicationState{}

  @type t :: %__MODULE__{
          drain: Exiron.Hub.Drain.t(),
          enabled?: boolean(),
          boot_failed?: boolean(),
          telegram_pollers_enabled?: boolean(),
          telegram_pollers: map(),
          telegram_last_polled_at: DateTime.t() | nil,
          router: Router.t() | nil,
          telegram: Telegram.t() | nil,
          runtime_options: keyword(),
          settings: Settings.t(),
          delivery: DeliveryState.t(),
          activity: ActivityState.t(),
          health: map(),
          configuration_digest: binary() | nil,
          configuration_activated_at: DateTime.t() | nil,
          configuration_reload_failed?: boolean(),
          lookups: LookupState.t(),
          publication: PublicationState.t()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs \\ %{}) do
    struct(__MODULE__, attrs)
  end
end
