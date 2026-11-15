defmodule HuddleWeb.HomeLive do
  @moduledoc """
  The landing page: create a board or jump into a recent one. The list of
  recent boards updates live as boards are created anywhere.
  """
  use HuddleWeb, :live_view

  alias Huddle.Boards
  alias Huddle.Boards.Board

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Boards.subscribe_boards()

    {:ok,
     socket
     |> assign(:page_title, "Real-time boards")
     |> assign(:form, to_form(Boards.change_board(%Board{})))
     |> assign(:boards, Boards.list_recent_boards())}
  end

  @impl true
  def handle_event("validate", %{"board" => board_params}, socket) do
    changeset =
      %Board{}
      |> Boards.change_board(board_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create", %{"board" => board_params}, socket) do
    case Boards.create_board(board_params) do
      {:ok, board} ->
        {:noreply, push_navigate(socket, to: ~p"/b/#{board.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_info({:board_created, _board}, socket) do
    {:noreply, assign(socket, :boards, Boards.list_recent_boards())}
  end

  defp features do
    [
      %{
        icon: "hero-bolt",
        title: "Instant sync",
        text: "Changes are broadcast over Phoenix PubSub to every open browser."
      },
      %{
        icon: "hero-cursor-arrow-rays",
        title: "Live cursors",
        text: "See who is online and where they are pointing, powered by Presence."
      },
      %{
        icon: "hero-chat-bubble-left-right",
        title: "Built-in chat",
        text: "Talk next to the work, with typing indicators and an activity feed."
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} return_to={~p"/"}>
      <div class="mx-auto w-full max-w-5xl px-4 py-12 sm:px-6 sm:py-20">
        <section class="text-center">
          <p class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-200 px-3 py-1 text-xs font-medium text-base-content/70">
            <span class="size-2 rounded-full bg-success motion-safe:animate-pulse"></span>
            Elixir · Phoenix LiveView · PubSub · Presence
          </p>
          <h1 class="mt-6 text-4xl font-semibold tracking-tight sm:text-6xl">
            Plan together,
            <span class="bg-linear-to-r from-primary to-accent bg-clip-text text-transparent">
              live.
            </span>
          </h1>
          <p class="mx-auto mt-4 max-w-xl text-base text-base-content/70 sm:text-lg">
            A shared board where every card, cursor and chat message shows up on
            everyone's screen the moment it happens. No sign-up, just share the link.
          </p>

          <.form
            for={@form}
            id="new-board-form"
            phx-change="validate"
            phx-submit="create"
            class="mx-auto mt-8 flex max-w-md items-start gap-2 text-left"
          >
            <div class="flex-1">
              <.input
                field={@form[:name]}
                type="text"
                placeholder="Name your board, e.g. Sprint 12"
                autocomplete="off"
              />
            </div>
            <.button variant="primary" phx-disable-with="Creating…">Create board</.button>
          </.form>
        </section>

        <section class="mt-14 grid gap-4 sm:grid-cols-3">
          <div
            :for={feature <- features()}
            class="rounded-2xl border border-base-300 bg-base-200/50 p-5"
          >
            <.icon name={feature.icon} class="size-6 text-primary" />
            <h2 class="mt-3 text-sm font-semibold">{feature.title}</h2>
            <p class="mt-1 text-sm text-base-content/70">{feature.text}</p>
          </div>
        </section>

        <section class="mt-14">
          <h2 class="text-sm font-semibold tracking-wide text-base-content/60 uppercase">
            Recent boards
          </h2>
          <p
            :if={@boards == []}
            id="boards-empty"
            class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60"
          >
            No boards yet. Create the first one above.
          </p>
          <ul id="boards" class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <li :for={%{board: board, card_count: card_count} <- @boards} id={"board-#{board.id}"}>
              <.link
                navigate={~p"/b/#{board.slug}"}
                class="group flex items-center gap-3 rounded-2xl border border-base-300 bg-base-100 p-4 transition hover:-translate-y-0.5 hover:border-primary hover:shadow-lg"
              >
                <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary">
                  <.icon name="hero-view-columns" class="size-5" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-semibold">{board.name}</span>
                  <span class="block text-xs text-base-content/60">
                    {card_count} {if card_count == 1, do: "card", else: "cards"}
                  </span>
                </span>
                <.icon
                  name="hero-arrow-right-micro"
                  class="size-4 text-base-content/40 transition group-hover:translate-x-0.5 group-hover:text-primary"
                />
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
