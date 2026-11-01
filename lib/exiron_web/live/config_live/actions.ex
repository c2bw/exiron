defmodule ExironWeb.ConfigLive.Actions do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4]

  alias Exiron.Hub.{
    ConfigurationDiff,
    ConfigurationDiagnostics,
    ConfigurationHistory,
    ConfigurationService,
    HookToken,
    RouteConfiguration
  }

  alias ExironWeb.ConfigLive.{RouteTesting, State}

  @structured_events %{
    "put_telegram_bot" => {&RouteConfiguration.put_telegram_bot/2, :telegram_bot},
    "put_chat_route" => {&RouteConfiguration.put_chat_route/2, :chat_route},
    "put_middleware_route" => {&RouteConfiguration.put_middleware_route/2, :middleware_route},
    "put_hook" => {&RouteConfiguration.put_hook/2, :hook}
  }

  def validate_source(socket, source) do
    normalized_source = HookToken.normalize_source_hooks(source)

    status =
      case RouteConfiguration.load_source(
             State.route_path(socket.assigns.route_configuration),
             normalized_source
           ) do
        {:ok, config} ->
          {:valid, State.summary(config)}

        {:error, reason} ->
          {:invalid, State.error_message(reason)}
      end

    socket = State.update_editor(socket, %{status: status, form: source_form(source)})

    if socket.assigns.pending_change && socket.assigns.pending_change.source != normalized_source,
      do: cancel_review(socket),
      else: socket
  end

  def review_source(socket, source),
    do: stage(socket, HookToken.normalize_source_hooks(source), :save)

  def review_rollback(socket, id) do
    path = State.route_path(socket.assigns.route_configuration)

    case ConfigurationHistory.fetch(path, id) do
      {:ok, source} -> stage(socket, source, :rollback, id)
      {:error, reason} -> put_flash(socket, :error, ConfigurationService.error_message(reason))
    end
  end

  def cancel_review(socket) do
    socket
    |> assign(:pending_change, nil)
    |> stream(:review_diagnostics, [], reset: true, dom_id: &"review-warning-#{&1.id}")
    |> stream(:config_diff, [], reset: true, dom_id: &"config-diff-#{&1.id}")
  end

  def confirm_review(%{assigns: %{pending_change: nil}} = socket), do: socket

  def confirm_review(%{assigns: %{pending_change: %{diff: %{truncated?: true}}}} = socket),
    do: put_flash(socket, :error, "This change is too large to review. Make smaller changes.")

  def confirm_review(socket) do
    pending = socket.assigns.pending_change
    save_source(socket, pending.source, pending.kind)
  end

  defp stage(socket, source, kind, revision_id \\ nil) do
    path = State.route_path(socket.assigns.route_configuration)

    with {:ok, current} <- ConfigurationService.current_source(path),
         true <- current == socket.assigns.persisted_source,
         {:ok, config} <- RouteConfiguration.load_source(path, source),
         {:ok, diff} <- ConfigurationDiff.preview(current, source) do
      if diff.changed? do
        warnings = ConfigurationDiagnostics.analyze(config)

        socket
        |> assign(:pending_change, %{
          source: source,
          kind: kind,
          revision_id: revision_id,
          diagnostic_count: length(warnings),
          diff: Map.delete(diff, :lines)
        })
        |> stream(:review_diagnostics, warnings, reset: true, dom_id: &"review-warning-#{&1.id}")
        |> stream(:config_diff, diff.lines, reset: true, dom_id: &"config-diff-#{&1.id}")
      else
        socket |> cancel_review() |> put_flash(:info, "No configuration changes to review.")
      end
    else
      false ->
        put_flash(
          socket,
          :error,
          "Configuration changed on disk. Reload the page before reviewing again."
        )

      {:error, reason} ->
        socket
        |> cancel_review()
        |> put_flash(:error, ConfigurationService.error_message(reason))
        |> State.update_editor(%{status: {:invalid, ConfigurationService.error_message(reason)}})
    end
  end

  def save_source(socket, source, kind \\ :save) do
    path = State.route_path(socket.assigns.route_configuration)
    expected_source = socket.assigns.persisted_source

    case ConfigurationService.save_and_reload(path, source, expected_source: expected_source) do
      {:ok, %{configuration: configuration, reload: reload, history: history}} ->
        route_configuration = {:ok, configuration}
        verb = if kind == :rollback, do: "restored", else: "saved"

        socket
        |> cancel_review()
        |> assign_saved_source(route_configuration, source)
        |> put_reload_flash(
          reload,
          "Configuration #{verb} and activated.",
          "Configuration #{verb}, but not activated: Hub is disabled.",
          "Configuration #{verb}, but activation failed. Check the activation status below."
        )
        |> State.assign_diagnostics()
        |> State.assign_route_tester()
        |> State.assign_history()
        |> State.reset_editor_forms()
        |> history_flash(history)

      {:error, reason} ->
        message = ConfigurationService.error_message(reason)

        socket
        |> put_flash(:error, message)
        |> State.update_editor(%{status: {:invalid, message}, form: source_form(source)})
    end
  end

  def put_structured_change(socket, event, params) do
    case Map.fetch(@structured_events, event) do
      {:ok, {change_fun, form_name}} ->
        attrs = Map.get(params, Atom.to_string(form_name), %{})
        apply_structured_change(socket, change_fun, attrs, form_name)

      :error ->
        socket
    end
  end

  defp apply_structured_change(socket, change_fun, attrs, form_name) do
    source = socket.assigns.persisted_source
    path = State.route_path(socket.assigns.route_configuration)

    with {:ok, source} <- change_fun.(source, attrs),
         {:ok, _configuration} <- RouteConfiguration.load_source(path, source) do
      stage(socket, HookToken.normalize_source_hooks(source), :save)
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, ConfigurationService.error_message(reason))
        |> State.update_editor_form(form_name, attrs)
    end
  end

  defp history_flash(socket, {:ok, _id}), do: socket

  defp history_flash(socket, {:error, _reason}) do
    previous = Phoenix.Flash.get(socket.assigns.flash, :error)
    message = "The file was saved, but its new history checkpoint could not be written."
    put_flash(socket, :error, Enum.join(Enum.reject([previous, message], &is_nil/1), " "))
  end

  def test_route(socket, attrs) do
    socket
    |> assign(:route_tester_form, to_form(attrs, as: :route_tester))
    |> assign(
      :route_tester_result,
      RouteTesting.test_route(socket.assigns.route_configuration, attrs)
    )
  end

  def activate_saved(socket) do
    result =
      ConfigurationService.activate_saved(
        State.route_path(socket.assigns.route_configuration),
        socket.assigns.persisted_source
      )

    socket
    |> State.assign_activation()
    |> put_reload_flash(
      result,
      "Saved configuration activated.",
      "Saved configuration is not active: Hub is disabled.",
      "Activation failed. Check the activation status below."
    )
  end

  defp assign_saved_source(socket, route_configuration, source) do
    socket
    |> assign(:route_configuration, route_configuration)
    |> assign(:persisted_source, source)
    |> State.assign_activation()
    |> State.update_editor(%{
      status: State.editor_status(route_configuration),
      form: source_form(source)
    })
  end

  defp source_form(source), do: to_form(%{"source" => source}, as: :config)

  defp put_reload_flash(socket, reload, success_message, disabled_message, failure_prefix) do
    case reload do
      :ok ->
        if socket.assigns.activation.status == :active do
          put_flash(socket, :info, success_message)
        else
          put_flash(
            socket,
            :error,
            "File saved, but this version is not confirmed active. Check the activation status below."
          )
        end

      {:error, :disabled} ->
        put_flash(socket, :error, disabled_message)

      {:error, :activation_unconfirmed} ->
        put_flash(
          socket,
          :error,
          "File saved. Activation could not be confirmed; check its status before retrying."
        )

      {:error, %Exiron.Hub.RouteConfiguration.ConflictError{} = reason} ->
        put_flash(socket, :error, ConfigurationService.error_message(reason))

      {:error, _reason} ->
        put_flash(socket, :error, failure_prefix)
    end
  end
end
