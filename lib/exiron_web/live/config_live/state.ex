defmodule ExironWeb.ConfigLive.State do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [stream: 4]

  alias Exiron.Hub.{
    ConfigurationDiagnostics,
    ConfigurationHistory,
    ConfigurationService,
    RouteConfiguration
  }

  alias ExironWeb.ConfigLive.RouteTesting

  def assign_initial(socket) do
    route_configuration = load_route_configuration()

    persisted_source =
      case ConfigurationService.current_source(route_path(route_configuration)) do
        {:ok, source} -> source
        _ -> ""
      end

    socket
    |> assign(:route_configuration, route_configuration)
    |> assign(:persisted_source, persisted_source)
    |> assign(:editor, editor_state(route_configuration))
    |> update_editor(%{
      form:
        to_form(
          %{"source" => if(String.valid?(persisted_source), do: persisted_source, else: "")},
          as: :config
        )
    })
    |> assign(:pending_change, nil)
    |> stream(:review_diagnostics, [], reset: true, dom_id: &"review-warning-#{&1.id}")
    |> assign_diagnostics()
    |> stream(:config_diff, [], reset: true, dom_id: &"config-diff-#{&1.id}")
    |> assign_activation()
    |> assign_history()
    |> assign_route_tester()
  end

  def assign_diagnostics(socket) do
    warnings =
      case socket.assigns.route_configuration do
        {:ok, config} -> ConfigurationDiagnostics.analyze(config)
        _ -> []
      end

    socket
    |> assign(:diagnostic_count, length(warnings))
    |> stream(:config_diagnostics, warnings, reset: true, dom_id: &"config-warning-#{&1.id}")
  end

  def assign_history(socket) do
    path = route_path(socket.assigns.route_configuration)
    # Seed a valid starting file when opening the editor, including deployments
    # upgraded before their first checkpoint-aware boot/reload.
    checkpoint =
      if match?({:ok, _}, socket.assigns.route_configuration) do
        ConfigurationHistory.checkpoint(path, socket.assigns.persisted_source)
      else
        {:ok, nil}
      end

    {revisions, error} =
      case ConfigurationHistory.list(path) do
        {:ok, records} ->
          {records,
           if(match?({:error, _}, checkpoint),
             do:
               "Could not checkpoint the current configuration. Check history directory permissions and disk space."
           )}

        {:error, _reason} ->
          {[],
           "Configuration history is unavailable. Check directory permissions and disk space."}
      end

    current_id = ConfigurationHistory.digest(socket.assigns.persisted_source)
    revisions = Enum.map(revisions, &Map.put(&1, :current?, &1.id == current_id))

    previous =
      revisions
      |> Enum.filter(&(&1.valid? and not &1.current?))
      |> Enum.sort_by(&{&1.activated_at || "", &1.saved_at}, :desc)
      |> List.first()

    socket
    |> assign(:history_error, error)
    |> assign(:history_count, length(revisions))
    |> assign(:previous_revision_id, previous && previous.id)
    |> stream(:config_revisions, revisions, reset: true, dom_id: &"config-revision-#{&1.id}")
  end

  def assign_activation(socket) do
    source = socket.assigns.persisted_source
    configuration = socket.assigns.route_configuration

    unchanged? =
      match?({:ok, ^source}, ConfigurationService.current_source(route_path(configuration)))

    activation =
      if not unchanged? do
        %{status: :changed, activated_at: nil}
      else
        case configuration do
          {:error, _path, _reason} ->
            %{status: :invalid, activated_at: nil}

          {:ok, config} ->
            case RouteConfiguration.load(config.path) do
              {:ok, %{source: ^source}} -> activation_status(source)
              _changed -> %{status: :changed, activated_at: nil}
            end
        end
      end

    assign(socket, :activation, activation)
  end

  defp activation_status(source) do
    Exiron.Hub.configuration_status(source)
  catch
    :exit, _reason -> %{status: :unavailable, activated_at: nil}
  end

  def editor_state(route_configuration) do
    %{
      open?: false,
      status: editor_status(route_configuration),
      form: to_form(editor_params(route_configuration), as: :config),
      quick_forms: empty_quick_forms()
    }
  end

  def load_route_configuration do
    path =
      :exiron
      |> Application.get_env(:hub, [])
      |> Keyword.get(:config_path, "config/config.yml")

    case RouteConfiguration.load(path) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, path, reason}
    end
  end

  def route_path({:ok, config}), do: config.path
  def route_path({:error, path, _reason}), do: path

  def editor_params({:ok, config}), do: %{"source" => config.source}
  def editor_params({:error, _path, _reason}), do: %{"source" => ""}

  def editor_status({:ok, config}), do: {:valid, summary(config)}
  def editor_status({:error, _path, reason}), do: {:invalid, error_message(reason)}

  def summary(config) do
    %{
      chats: map_size(config.aliases),
      telegram_bots: length(config.bots),
      telegram_chats:
        config.bots |> Enum.flat_map(& &1.chat_ids) |> MapSet.new() |> MapSet.size(),
      routes: length(config.resolved_routes),
      middlewares: length(config.middlewares),
      hooks: length(config.hooks)
    }
  end

  def editor_status_text({:valid, _summary}), do: "Valid"
  def editor_status_text({:invalid, _reason}), do: "Invalid"

  def editor_status_class({:valid, _summary}) do
    "rounded-full bg-emerald-500/10 px-2 py-1 text-xs font-medium text-emerald-700 dark:bg-emerald-400/15 dark:text-emerald-300"
  end

  def editor_status_class({:invalid, _reason}) do
    "rounded-full bg-rose-500/10 px-2 py-1 text-xs font-medium text-rose-700 dark:bg-rose-400/15 dark:text-rose-300"
  end

  def compact_input_class do
    "w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 text-sm text-base-content shadow-sm transition focus:border-primary focus:outline-none focus:ring-2 focus:ring-primary/20"
  end

  defdelegate error_message(reason), to: ConfigurationService

  def update_editor(socket, updates) do
    update(socket, :editor, &Map.merge(&1, Map.new(updates)))
  end

  def update_editor_form(socket, form_name, attrs) do
    update_editor(socket, %{
      quick_forms:
        Map.put(
          socket.assigns.editor.quick_forms,
          form_name,
          to_form(attrs, as: form_name)
        )
    })
  end

  def reset_editor_forms(socket) do
    update_editor(socket, %{quick_forms: empty_quick_forms()})
  end

  defp empty_quick_forms do
    %{
      telegram_bot: to_form(%{}, as: :telegram_bot),
      chat_route: to_form(%{}, as: :chat_route),
      middleware_route: to_form(%{}, as: :middleware_route),
      hook: to_form(%{}, as: :hook)
    }
  end

  def assign_route_tester(socket) do
    params = RouteTesting.route_tester_params(socket.assigns.route_configuration)

    socket
    |> assign(:route_tester_form, to_form(params, as: :route_tester))
    |> assign(
      :route_tester_result,
      RouteTesting.test_route(socket.assigns.route_configuration, params)
    )
  end

  def current_source({:ok, config}), do: config.source
  def current_source({:error, _path, _reason}), do: ""
end
