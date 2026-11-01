defmodule ExironWeb.MonitorLive.ClientConnection do
  @moduledoc false
  use ExironWeb, :html
  alias ExironWeb.MonitorLive.ClientRuntime

  def label("never_seen"), do: "No client contact recorded"
  def label("unassigned"), do: "Not yet delivered to a client"
  def label("http_polling"), do: "HTTP poll lease active"
  def label("http_lease_expired"), do: "No recent HTTP poll"
  def label("websocket_connected"), do: "WebSocket connected"
  def label("websocket_disconnected"), do: "WebSocket disconnected"
  def label("different_client"), do: "Another client is connected"

  def version_label(client) do
    case {Map.get(client, :client_sdk), Map.get(client, :client_version)} do
      {"go", version} when is_binary(version) -> "Go SDK · " <> version
      {"elixir", version} when is_binary(version) -> "Elixir SDK · " <> version
      _ -> "Version not reported"
    end
  end

  attr :id, :string, required: true
  attr :client, :map, required: true
  attr :recipient?, :boolean, default: false

  def summary(assigns) do
    ~H"""
    <div id={@id} class="mt-3 min-w-0 space-y-1 text-[11px] text-base-content/60">
      <p id={@id <> "-identity"} class="break-all font-mono font-semibold text-base-content/80">
        {if @recipient?, do: "Last recipient", else: "Client"}: {@client.client_id || "None yet"}
      </p>
      <p id={@id <> "-version"} class="break-all font-mono text-base-content/60">
        {version_label(@client)}
      </p>
      <p
        id={@id <> "-state"}
        data-state={@client.state}
        class={[
          "font-semibold",
          @client.state in ["websocket_disconnected", "http_lease_expired", "different_client"] &&
            "text-amber-700 dark:text-amber-300"
        ]}
      >
        {label(@client.state)}
      </p>
      <p :if={@client.state == "different_client"} class="break-all">
        Current client: {@client.current_client_id}
      </p>
      <p id={@id <> "-last-contact"}>
        Last identified contact:
        <%= if @client.last_contact_at do %>
          <time datetime={DateTime.to_iso8601(@client.last_contact_at)}>{Calendar.strftime(
            @client.last_contact_at,
            "%Y-%m-%d %H:%M:%S UTC"
          )}</time>
          · {@client.last_contact_kind}
        <% else %>
          Not recorded for this client
        <% end %>
      </p>
      <p :if={Map.has_key?(@client, :awaiting_response)} id={@id <> "-work"}>
        {@client.awaiting_response} awaiting response · {@client.sending_requests} sending
        <span :if={@client.other_assigned_requests > 0}> · {@client.other_assigned_requests} assigned to other or unknown clients</span>
      </p>
      <ClientRuntime.summary
        :if={Map.has_key?(@client, :awaiting_response)}
        id={@id <> "-runtime"}
        report={Map.get(@client, :runtime)}
      />
      <p :if={@client.state == "http_lease_expired"} id={@id <> "-explanation"}>
        HTTP clients can stop polling while processing. This does not prove a disconnect.
      </p>
      <p :if={@client.state == "websocket_disconnected"} id={@id <> "-explanation"}>
        The registered socket has disconnected. Outstanding work may need redelivery or a later response.
      </p>
    </div>
    """
  end
end
