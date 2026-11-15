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
    <div class={[
      "flex flex-col bg-base-100 text-base-content",
      if(@fill, do: "h-dvh overflow-hidden", else: "min-h-dvh")
    ]}>
      <header class="flex h-16 shrink-0 items-center gap-3 border-b border-base-300 px-4 sm:px-6">
        <.link navigate={~p"/"} id="home-link" class="flex items-center gap-2">
          <span class="grid size-8 place-items-center rounded-xl bg-primary text-primary-content shadow-sm">
            <.icon name="hero-squares-2x2-solid" class="size-5" />
          </span>
          <span class="text-lg font-semibold tracking-tight">Huddle</span>
        </.link>

        <div class="flex-1"></div>

        <.theme_toggle />

        <details :if={@current_user} id="user-menu" class="dropdown dropdown-end">
          <summary class="btn btn-ghost gap-2 px-2">
            <.avatar name={@current_user["name"]} color={@current_user["color"]} />
            <span class="hidden max-w-32 truncate text-sm sm:inline">{@current_user["name"]}</span>
          </summary>
          <div class="dropdown-content z-50 mt-2 w-64 rounded-2xl border border-base-300 bg-base-100 p-4 shadow-xl">
            <.form
              for={%{}}
              action={~p"/session"}
              method="post"
              id="rename-form"
              class="space-y-2"
            >
              <label for="rename-input" class="text-xs font-medium text-base-content/70">
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
                class="input input-sm w-full"
              />
              <button type="submit" class="btn btn-primary btn-sm w-full">Save</button>
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
        "grid shrink-0 place-items-center rounded-full font-semibold text-white select-none",
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
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
