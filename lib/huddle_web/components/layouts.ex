defmodule HuddleWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HuddleWeb, :html

  alias Huddle.Identity

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell: the top bar with the visitor's identity, then the page.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "the visitor's guest identity"
  attr :return_to, :string, default: "/", doc: "where to go back to after renaming"
  attr :fill, :boolean, default: false, doc: "lock the page to the viewport height"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="h-aurora" aria-hidden="true"><i></i><i></i><i></i></div>

    <div class={[
      "flex flex-col text-base-content",
      if(@fill, do: "h-dvh overflow-hidden", else: "min-h-dvh")
    ]}>
      <header class="h-glass relative z-40 flex h-14 shrink-0 items-center gap-3 border-x-0 border-t-0 px-4 sm:px-6">
        <.link navigate={~p"/"} id="home-link" class="group flex items-center gap-2.5">
          <span class="grid size-8 place-items-center rounded-xl bg-linear-to-br from-primary to-accent text-primary-content shadow-lg shadow-primary/30 transition-transform duration-300 group-hover:scale-110 group-hover:-rotate-6">
            <.icon name="hero-fire-solid" class="size-5" />
          </span>
          <span class="font-display text-lg font-bold">Huddle</span>
        </.link>

        <div class="flex-1"></div>

        <.theme_toggle />

        <details :if={@current_user} id="user-menu" class="relative">
          <summary class="h-btn h-btn-ghost list-none gap-2 px-1.5 [&::-webkit-details-marker]:hidden">
            <.avatar name={@current_user["name"]} color={@current_user["color"]} />
            <span class="hidden max-w-32 truncate text-sm sm:inline">{@current_user["name"]}</span>
            <.icon name="hero-chevron-down-micro" class="size-4 text-muted" />
          </summary>
          <div class="h-menu h-glass absolute right-0 z-50 mt-2 w-64 rounded-2xl !bg-base-100 p-4 shadow-2xl">
            <.form
              for={%{}}
              action={~p"/session"}
              method="post"
              id="rename-form"
              class="space-y-2"
            >
              <label for="rename-input" class="text-muted text-xs font-medium">
                Your display name
              </label>
              <input type="hidden" name="return_to" value={@return_to} />
              <input
                id="rename-input"
                type="text"
                name="user[name]"
                value={@current_user["name"]}
                maxlength="24"
                required
                class="h-input"
              />
              <button type="submit" class="h-btn h-btn-primary w-full">Save</button>
            </.form>
          </div>
        </details>
      </header>

      <main class="flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  A round avatar showing a person's initials on their colour.
  """
  attr :name, :string, required: true
  attr :color, :string, required: true
  attr :class, :any, default: "size-7 text-xs"
  attr :rest, :global

  def avatar(assigns) do
    ~H"""
    <span
      class={[
        "grid shrink-0 place-items-center rounded-full font-bold text-white select-none",
        @class
      ]}
      style={"background-color: #{@color}"}
      {@rest}
    >
      {Identity.initials(@name)}
    </span>
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
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
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
    <div
      id="theme-toggle"
      class="relative flex items-center rounded-full border border-[var(--line)] bg-[var(--soft)] p-0.5"
    >
      <div class="absolute top-0.5 bottom-0.5 left-0.5 w-7 rounded-full bg-base-100 shadow-sm transition-transform duration-300 ease-[var(--ease-spring)] [[data-theme=light]_&]:translate-x-7 [[data-theme=dark]_&]:translate-x-14 [[data-theme-source=system]_&]:!translate-x-0" />

      <button
        :for={
          {theme, icon} <- [
            {"system", "hero-computer-desktop-micro"},
            {"light", "hero-sun-micro"},
            {"dark", "hero-moon-micro"}
          ]
        }
        type="button"
        class="relative grid size-7 cursor-pointer place-items-center opacity-60 transition hover:opacity-100"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={"Use #{theme} theme"}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
