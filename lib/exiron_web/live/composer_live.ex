defmodule ExironWeb.ComposerLive do
  use ExironWeb, :live_view
  alias Exiron.Hub

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Hub.subscribe_configuration()
    targets = Hub.manual_targets()
    selected = Enum.find(targets, &(&1.hook == params["hook"]))

    {:ok,
     socket
     |> assign(:page_title, "Compose message")
     |> assign(:targets, targets)
     |> assign(:draft, nil)
     |> assign(:sending?, false)
     |> allow_upload(:attachment,
       accept: :any,
       max_entries: 1,
       max_file_size: Exiron.Hub.ManualAttachment.max_bytes(),
       auto_upload: true,
       progress: &upload_progress/3
     )
     |> assign(:last_destination, if(selected, do: selected.id, else: ""))
     |> assign(:explicit_destination?, not is_nil(selected))
     |> assign(
       :form,
       to_form(
         %{
           "target" => if(selected, do: selected.id, else: ""),
           "text" => "",
           "topic" => "",
           "datatype" => "text"
         },
         as: :message
       )
     )}
  end

  @impl true
  def handle_info(:configuration_changed, socket) do
    targets = Hub.manual_targets()
    socket = assign(socket, :targets, targets)
    current = socket.assigns.form.params["target"]

    socket =
      if Enum.any?(targets, &(&1.id == current)) do
        socket
      else
        socket
        |> assign(:form, to_form(Map.put(socket.assigns.form.params, "target", ""), as: :message))
        |> assign(:last_destination, "")
        |> push_event("composer_destination", %{target: ""})
      end

    {:noreply, if(socket.assigns.sending?, do: socket, else: assign(socket, :draft, nil))}
  end

  @impl true
  def handle_event("restore_destination", %{"target" => target}, socket) do
    if not socket.assigns.explicit_destination? and
         socket.assigns.form.params["target"] in [nil, ""] and
         Enum.any?(Hub.manual_targets(), &(&1.id == target)) do
      {:noreply,
       socket
       |> assign(:last_destination, target)
       |> assign(
         :form,
         to_form(Map.put(socket.assigns.form.params, "target", target), as: :message)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change", %{"message" => params}, socket) do
    if socket.assigns.sending? do
      {:noreply, socket}
    else
      old_type = Map.get(socket.assigns.form.params, "datatype", "text")
      params = Map.put_new(params, "datatype", "text")
      socket = if old_type != params["datatype"], do: clear_uploads(socket), else: socket

      {:noreply,
       socket
       |> assign(:draft, nil)
       |> assign(:form, to_form(params, as: :message))
       |> remember_destination(params)}
    end
  end

  def handle_event("preview", %{"message" => params}, socket) do
    if socket.assigns.sending? do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:form, to_form(params, as: :message))
        |> assign(:targets, Hub.manual_targets())
        |> assign(:draft, nil)

      result =
        with {:ok, params} <- attachment_params(socket, params), do: Hub.preview_manual(params)

      case result do
        {:ok, draft} ->
          {:noreply, socket |> assign(:draft, draft) |> remember_destination(params)}

        _ ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Choose a destination and review the message limits. Photos and files need one completed upload (up to 10 MB) and an optional caption of up to 1024 Telegram characters. A topic must be a positive number."
           )}
      end
    end
  end

  def handle_event("send", _, %{assigns: %{sending?: false, draft: %{} = draft}} = socket) do
    {:noreply,
     socket
     |> assign(:sending?, true)
     |> start_async(:send_manual, fn -> Hub.send_manual(draft) end)}
  end

  def handle_event("send", _, socket), do: {:noreply, socket}

  def handle_event("remove_attachment", _, %{assigns: %{sending?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("remove_attachment", _, socket),
    do: {:noreply, socket |> clear_uploads() |> assign(:draft, nil)}

  @impl true
  def handle_async(:send_manual, result, socket) do
    socket =
      socket
      |> assign(:sending?, false)
      |> assign(:draft, nil)
      |> assign(:targets, Hub.manual_targets())

    socket =
      case result do
        {:ok, {:ok, _}} ->
          socket
          |> clear_uploads()
          |> assign(
            :form,
            to_form(
              %{
                "target" => socket.assigns.last_destination,
                "text" => "",
                "topic" => "",
                "datatype" => Map.get(socket.assigns.form.params, "datatype", "text")
              },
              as: :message
            )
          )
          |> push_event("composer_sent", %{})
          |> put_flash(:info, "Message sent.")

        {:ok, {:error, reason}}
        when reason in [
               :stale_draft,
               :draining,
               :disabled,
               :send_queue_full,
               :hook_send_queue_full,
               :send_unavailable,
               :idempotency_capacity_exceeded
             ] ->
          put_flash(
            socket,
            :error,
            "Message was not admitted. Review the current destination and preview again."
          )

        _ ->
          put_flash(
            socket,
            :error,
            "Delivery could not be confirmed. Inspect the monitor before trying again."
          )
      end

    {:noreply, socket}
  end

  defp upload_progress(_name, _entry, socket) do
    if socket.assigns.sending? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:draft, nil)
       |> push_event("composer_attachment", %{
         present: socket.assigns.uploads.attachment.entries != []
       })}
    end
  end

  defp clear_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.attachment.entries, socket, fn entry, socket ->
      cancel_upload(socket, :attachment, entry.ref)
    end)
    |> push_event("composer_attachment", %{present: false})
  end

  defp attachment_params(socket, params) do
    if Map.get(params, "datatype", "text") == "text" do
      if socket.assigns.uploads.attachment.entries == [],
        do: {:ok, params},
        else: {:error, :unexpected_attachment}
    else
      case uploaded_entries(socket, :attachment) do
        {[entry], []} ->
          result =
            consume_uploaded_entry(socket, entry, fn %{path: path} ->
              result =
                with {:ok, %{size: size}} <- File.stat(path),
                     true <- size in 1..10_000_000,
                     {:ok, data} <- File.read(path),
                     do: {:ok, %{data: data, file_name: entry.client_name}}

              {:postpone, result}
            end)

          case result do
            {:ok, attachment} -> {:ok, Map.put(params, "attachment", attachment)}
            _ -> {:error, :invalid_attachment}
          end

        _ ->
          {:error, :upload_not_ready}
      end
    end
  end

  defp upload_error(:too_large), do: "File is larger than 10 MB."
  defp upload_error(:too_many_files), do: "Choose one attachment at a time."
  defp upload_error(_), do: "This attachment could not be uploaded."

  defp remember_destination(socket, params) do
    target = params["target"]

    if Enum.any?(socket.assigns.targets, &(&1.id == target)),
      do:
        socket
        |> assign(:last_destination, target)
        |> push_event("composer_destination", %{target: target}),
      else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:compose}>
      <section id="message-composer" class="mx-auto max-w-5xl space-y-5">
        <span id="composer-session" phx-hook="ComposerSession" phx-update="ignore" class="hidden" />
        <div class="ex-panel flex flex-wrap items-center justify-between gap-4 p-6">
          <div>
            <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-primary">
              Manual delivery
            </p><h1 class="mt-2 text-2xl font-black">Compose a message</h1><p class="mt-2 text-sm text-base-content/60">
              Choose a destination, review the message, then send.
            </p>
          </div>
          <.link navigate={~p"/monitor"} id="composer-monitor" class="ex-action-button">Open monitor</.link>
        </div>
        <p
          :if={@targets == []}
          id="composer-no-targets"
          class="ex-panel p-5 text-sm text-base-content/60"
        >
          No destinations are available. Enable push on a chat route with a configured Telegram bot.
        </p>
        <div class="grid min-w-0 gap-5 lg:grid-cols-2">
          <.form
            for={@form}
            id="composer-form"
            phx-change="change"
            phx-submit="preview"
            class="ex-panel min-w-0 space-y-4 p-5"
          >
            <.input
              field={@form[:target]}
              id="composer-target"
              type="select"
              label="Destination"
              prompt="Choose a hook, chat and bot"
              options={Enum.map(@targets, &{&1.label, &1.id})}
              disabled={@sending?}
            />
            <.input
              field={@form[:datatype]}
              id="composer-type"
              type="select"
              label="Message type"
              options={[{"Plain text", "text"}, {"Photo (PNG or JPEG)", "image"}, {"File", "file"}]}
              disabled={@sending?}
            />
            <.input
              field={@form[:topic]}
              id="composer-topic"
              type="number"
              min="1"
              max="2147483647"
              label="Topic ID (optional)"
              disabled={@sending?}
            />
            <.input
              field={@form[:text]}
              id="composer-text"
              type="textarea"
              label={
                if @form.params["datatype"] in ["image", "file"],
                  do: "Caption (optional)",
                  else: "Message"
              }
              rows="9"
              maxlength={if @form.params["datatype"] in ["image", "file"], do: "1024", else: "4096"}
              required={@form.params["datatype"] not in ["image", "file"]}
              disabled={@sending?}
            />
            <div
              :if={@form.params["datatype"] in ["image", "file"]}
              id="composer-attachment"
              class="space-y-3 rounded-xl border border-dashed border-base-300 p-4"
            >
              <label for={@uploads.attachment.ref} class="block text-sm font-semibold">Attachment · up to 10 MB</label>
              <.live_file_input
                upload={@uploads.attachment}
                data-composer-upload
                disabled={@sending?}
                class="block w-full min-w-0 text-xs file:mr-3 file:rounded-lg file:border file:border-base-300 file:bg-base-100 file:px-3 file:py-2 file:font-semibold"
              />
              <div
                :for={entry <- @uploads.attachment.entries}
                id={"composer-upload-#{entry.ref}"}
                class="min-w-0 space-y-2"
              >
                <p class="break-all text-xs font-semibold">{entry.client_name}</p>
                <progress
                  value={entry.progress}
                  max="100"
                  class="h-2 w-full accent-primary"
                  aria-label="Upload progress"
                />
                <p class="text-xs text-base-content/55">{entry.progress}% uploaded</p>
                <button
                  id={"composer-remove-#{entry.ref}"}
                  type="button"
                  phx-click="remove_attachment"
                  disabled={@sending?}
                  class="ex-action-button"
                >Remove attachment</button>
                <p
                  :for={error <- upload_errors(@uploads.attachment, entry)}
                  class="text-xs text-error"
                >
                  {upload_error(error)}
                </p>
              </div>
              <p :for={error <- upload_errors(@uploads.attachment)} class="text-xs text-error">
                {upload_error(error)}
              </p>
            </div>
            <p class="text-xs text-base-content/50">
              Sent exactly as plain text. A preview never sends a message.
            </p>
            <button
              id="composer-preview"
              type="submit"
              class="ex-action-button"
              disabled={@sending? or @targets == []}
              phx-disable-with="Preparing…"
            ><.icon name="hero-eye-micro" class="size-4" /> Preview message</button>
          </.form>
          <section id="composer-review" class="ex-panel min-w-0 p-5">
            <h2 class="text-sm font-black">Review before sending</h2>
            <%!-- Keep the blob preview mounted before form submission clears client file refs. --%>
            <div
              id="composer-photo-preview"
              class={["mt-5", !(@draft && @draft.datatype == "image") && "hidden"]}
            >
              <.live_img_preview
                :for={entry <- @uploads.attachment.entries}
                :if={@form.params["datatype"] == "image"}
                entry={entry}
                alt={entry.client_name}
                class="max-h-64 w-full rounded-xl border border-base-300 object-contain"
              />
            </div>
            <%= if @draft do %>
              <dl id="composer-destination" class="mt-4 space-y-2 text-xs">
                <div>
                  <dt class="text-base-content/50">Destination</dt><dd class="mt-1 break-words font-semibold">
                    {@draft.target.label}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Topic</dt><dd class="mt-1 font-mono">
                    {@draft.topic || "Main chat"}
                  </dd>
                </div>
              </dl>
              <div
                :if={@draft.attachment}
                id="composer-attachment-preview"
                class="mt-5 space-y-3 rounded-xl border border-base-300 p-4"
              >
                <div class="flex min-w-0 items-start gap-3">
                  <.icon name="hero-document-micro" class="size-5 shrink-0 text-primary" /><div class="min-w-0">
                    <p class="break-all text-sm font-semibold">{@draft.attachment.file_name}</p><p class="mt-1 text-xs text-base-content/55">
                      {@draft.attachment.bytes} bytes · {if @draft.datatype == "image",
                        do: "Photo",
                        else: "File"}
                    </p>
                  </div>
                </div>
              </div>
              <pre
                id="composer-message-preview"
                class="mt-5 whitespace-pre-wrap break-words rounded-xl border border-primary/15 bg-primary/5 p-4 font-sans text-sm [overflow-wrap:anywhere]"
              >{@draft.text}</pre>
              <p class="mt-4 text-xs text-base-content/50">
                This sends the reviewed message and attachment using the selected bot. Changes require a new preview.
              </p>
              <button
                id="composer-send"
                type="button"
                phx-click="send"
                disabled={@sending?}
                class="ex-action-button mt-4"
              ><.icon name="hero-paper-airplane-micro" class="size-4" /> {if @sending?,
                do: "Sending…",
                else: "Send message"}</button>
            <% else %>
              <div
                id="composer-preview-empty"
                class="mt-5 grid min-h-60 place-items-center rounded-xl border border-dashed border-base-300 p-6 text-center text-sm text-base-content/50"
              >
                Your preview will appear here.
              </div>
            <% end %>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
