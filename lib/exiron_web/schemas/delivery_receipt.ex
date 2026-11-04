defmodule ExironWeb.Schemas.DeliveryReceipt do
  @moduledoc false
  alias OpenApiSpex.Schema
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeliveryReceipt",
    type: :object,
    required: [:service_id, :chat_id, :message_ids],
    properties: %{
      service_id: %Schema{type: :integer},
      chat_id: %Schema{type: :integer},
      message_thread_id: %Schema{type: :integer, nullable: true},
      message_ids: %Schema{type: :array, items: %Schema{type: :integer, minimum: 1}}
    }
  })
end
