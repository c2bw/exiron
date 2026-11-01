defmodule ExironWeb.ConfigLive do
  use ExironWeb, :live_view

  alias ExironWeb.ConfigLive.{Actions, State}
  alias Exiron.Hub

  alias ExironWeb.ConfigLive.Components.{
    ConfigurationDetails,
    Configurator,
    Diagnostics,
    History,
    PageHeader
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Hub.subscribe_configuration()
    {:ok, State.assign_initial(socket)}
  end

  @impl true
  def handle_info(:configuration_changed, socket),
    do: {:noreply, socket |> State.assign_activation() |> State.assign_history()}

  @impl true
  def handle_event("toggle_editor", _params, socket) do
    {:noreply, State.update_editor(socket, open?: !socket.assigns.editor.open?)}
  end

  def handle_event("validate", %{"config" => %{"source" => source}}, socket) do
    {:noreply, Actions.validate_source(socket, source)}
  end

  def handle_event("save", %{"config" => %{"source" => source}}, socket) do
    {:noreply, Actions.review_source(socket, source)}
  end

  def handle_event("confirm_config", _params, socket),
    do: {:noreply, Actions.confirm_review(socket)}

  def handle_event("cancel_config_review", _params, socket),
    do: {:noreply, Actions.cancel_review(socket)}

  def handle_event("review_rollback", %{"id" => id}, socket),
    do: {:noreply, Actions.review_rollback(socket, id)}

  def handle_event("activate_saved", _params, socket),
    do: {:noreply, Actions.activate_saved(socket)}

  def handle_event("check_activation", _params, socket),
    do: {:noreply, State.assign_activation(socket)}

  def handle_event("test_route", %{"route_tester" => attrs}, socket) do
    {:noreply, Actions.test_route(socket, attrs)}
  end

  def handle_event(event, params, socket) do
    {:noreply, Actions.put_structured_change(socket, event, params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:config}>
      <div class="ex-config-workspace mx-auto flex max-w-7xl flex-col gap-3">
        <PageHeader.page_header route_configuration={@route_configuration} />
        <Configurator.activation_status activation={@activation} />
        <History.review
          pending={@pending_change}
          streams={@streams}
          stale?={@activation.status == :changed}
        />
        <History.history
          streams={@streams}
          error={@history_error}
          count={@history_count}
          previous_id={@previous_revision_id}
          stale?={@activation.status == :changed}
        />
        <Configurator.configurator editor={@editor} />
        <%= case @route_configuration do %>
          <% {:ok, config} -> %>
            <Diagnostics.diagnostics
              id="exiron-config-diagnostics"
              count={@diagnostic_count}
              entries={@streams.config_diagnostics}
            />
            <ConfigurationDetails.configuration_details
              config={config}
              route_tester_form={@route_tester_form}
              route_tester_result={@route_tester_result}
            />
          <% {:error, path, reason} -> %>
            <Configurator.config_error path={path} reason={reason} />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
