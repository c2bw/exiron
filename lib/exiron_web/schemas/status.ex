defmodule ExironWeb.Schemas.Status do
  @moduledoc false

  alias ExironWeb.Schemas.{
    BotMembership,
    ChatStatus,
    ClientEvent,
    Event,
    HookStatus,
    MembershipEvent,
    Route,
    SchemaHelpers,
    SendFailure
  }

  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Status",
    type: :object,
    required: [
      :enabled,
      :telegram_polling,
      :telegram_last_polled_at,
      :version,
      :requested,
      :chats,
      :hooks,
      :routes,
      :events,
      :send_failures,
      :overload_events,
      :membership_events,
      :bot_memberships,
      :client_events
    ],
    properties: %{
      enabled: %Schema{type: :boolean},
      telegram_polling: %Schema{type: :boolean},
      telegram_last_polled_at: SchemaHelpers.nullable_date_time(),
      version: %Schema{type: :string},
      requested: %Schema{type: :integer, minimum: 0},
      delivery_health: ExironWeb.Schemas.DeliveryHealth,
      chats: %Schema{type: :array, items: ChatStatus},
      hooks: %Schema{type: :array, items: HookStatus},
      routes: %Schema{type: :array, items: Route},
      events: %Schema{type: :array, items: Event},
      send_failures: %Schema{type: :array, items: SendFailure},
      overload_events: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            at: SchemaHelpers.date_time(),
            hook: %Schema{type: :string},
            reason: %Schema{type: :string},
            service_id: %Schema{type: :integer},
            chat_id: %Schema{type: :integer},
            datatype: %Schema{type: :string},
            payload_bytes: %Schema{type: :integer, minimum: 0}
          }
        }
      },
      membership_events: %Schema{type: :array, items: MembershipEvent},
      bot_memberships: %Schema{type: :array, items: BotMembership},
      client_events: %Schema{type: :array, items: ClientEvent}
    }
  })
end
