defmodule ExironWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ExironWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active_nav, :atom,
    default: nil,
    values: [nil, :overview, :monitor, :config, :compose],
    doc: "the currently active primary navigation item"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-40 bg-base-200/80 px-3 py-3 backdrop-blur-xl sm:px-5 lg:px-6">
      <div class="ex-app-header mx-auto max-w-[90rem]">
        <.link
          navigate={~p"/"}
          id="exiron-brand"
          class="group flex min-w-0 items-center gap-3 rounded-xl"
        >
          <span class="ex-brand-mark">
            <img src={~p"/images/logo.svg"} width="36" height="36" alt="" />
          </span>

          <span class="min-w-0 leading-none">
            <span class="flex items-center gap-2">
              <span class="text-[15px] font-black tracking-[-0.04em] text-base-content">
                EXIRON
              </span>
              <span class="hidden rounded-full border border-primary/20 bg-primary/8 px-1.5 py-0.5 font-mono text-[7px] font-bold uppercase tracking-[0.15em] text-primary sm:inline">
                Control
              </span>
            </span>
            <span class="mt-1.5 block truncate font-mono text-[8px] font-semibold uppercase tracking-[0.17em] text-base-content/35">
              Message infrastructure
            </span>
          </span>
        </.link>

        <nav
          :if={@current_scope}
          id="primary-navigation"
          aria-label="Primary navigation"
          class="ex-app-nav"
        >
          <ul class="grid grid-cols-3 gap-1">
            <li>
              <.app_nav_link
                id="nav-overview"
                href={~p"/"}
                label="Overview"
                icon="hero-squares-2x2-micro"
                active={@active_nav == :overview}
              />
            </li>
            <li>
              <.app_nav_link
                id="nav-monitor"
                href={~p"/monitor"}
                label="Monitor"
                icon="hero-signal-micro"
                active={@active_nav == :monitor}
              />
            </li>
            <li>
              <.app_nav_link
                id="nav-config"
                href={~p"/config"}
                label="Configure"
                icon="hero-adjustments-horizontal-micro"
                active={@active_nav == :config}
              />
            </li>
          </ul>
        </nav>

        <div class="ex-header-tools ml-auto flex items-center gap-2">
          <div :if={@current_scope} class="ex-system-pill">
            <span class="relative flex size-2">
              <span class="absolute inline-flex size-full animate-ping rounded-full bg-emerald-500 opacity-40" />
              <span class="relative inline-flex size-2 rounded-full bg-emerald-500" />
            </span>
            <span class="hidden lg:inline">Operational</span>
          </div>

          <.link
            :if={@current_scope}
            id="nav-compose"
            navigate={~p"/compose"}
            class="ex-header-action"
            aria-label="Compose a message"
            title="Compose a message"
            aria-current={if @active_nav == :compose, do: "page"}
          ><.icon name="hero-pencil-square-micro" class="size-4" /></.link>
          <.theme_toggle />

          <.link
            :if={@current_scope}
            href={~p"/logout"}
            method="delete"
            id="logout-link"
            class="ex-header-action"
            aria-label="Log out"
            title="Log out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
          </.link>

          <.link
            :if={!@current_scope}
            navigate={~p"/login"}
            id="login-link"
            class="ex-login-action"
          >
            <.icon name="hero-lock-closed-micro" class="size-4" /> Log in
          </.link>
        </div>
      </div>
    </header>

    <main class="px-3 pb-5 pt-2 sm:px-5 sm:pb-6 lg:px-6 lg:pb-7">
      <div class="mx-auto max-w-[90rem] space-y-5">
        {render_slot(@inner_block)}
      </div>
    </main>
    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  defp app_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      id={@id}
      aria-current={if(@active, do: "page", else: nil)}
      class={[
        "ex-app-nav-link",
        @active && "ex-app-nav-link-active"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div id="theme-controls" class="ex-theme-toggle" role="group" aria-label="Color theme">
      <div class="ex-theme-indicator" />
      <button
        class="ex-theme-button"
        type="button"
        aria-label="Use system theme"
        title="System theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="ex-theme-button"
        type="button"
        aria-label="Use light theme"
        title="Light theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="ex-theme-button"
        type="button"
        aria-label="Use dark theme"
        title="Dark theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
