defmodule HuddleWeb.HomeLive do
  @moduledoc """
  The landing page: create a board, or go back to one you have opened before.

  Boards are private to whoever has their link, so this page only lists the
  boards this visitor has already been to.
  """
  use HuddleWeb, :live_view

  alias Huddle.Boards
  alias Huddle.Boards.Board

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Real-time boards")
     |> assign(:form, to_form(Boards.change_board(%Board{})))
     |> assign(:boards, Boards.list_visited_boards(socket.assigns.current_user["id"]))}
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

  defp features do
    [
      %{
        icon: "hero-bolt",
        title: "Instant sync",
        text: "Every card, vote and reaction lands on everyone's screen the moment it happens."
      },
      %{
        icon: "hero-cursor-arrow-rays",
        title: "Live cursors",
        text: "See who is here and where they are pointing, like sitting at the same table."
      },
      %{
        icon: "hero-qr-code",
        title: "Share in a second",
        text: "Copy a link or show a QR code. Hand out a view-only link to people who just watch."
      },
      %{
        icon: "hero-presentation-chart-bar",
        title: "Present and follow",
        text: "Take the lead: everyone's board follows yours and your spotlight card glows."
      },
      %{
        icon: "hero-eye-slash",
        title: "Anonymous voting",
        text: "Hide the counts while people vote, then reveal them all at once."
      },
      %{
        icon: "hero-arrow-down-tray",
        title: "Take it with you",
        text: "Export the whole board as Markdown or a spreadsheet when the meeting ends."
      }
    ]
  end

  # The cards on the decorative board in the hero.
  defp demo_columns do
    [
      {"To do",
       [
         %{text: "Pick a name for the launch", color: "#f59e0b", label: "Idea", tilt: "-1.2deg"},
         %{text: "Fix the login redirect", color: "#a855f7", label: "Bug", tilt: "0.8deg"}
       ]},
      {"In progress",
       [
         %{text: "Draft the announcement", color: "#0ea5e9", label: "Question", tilt: "1deg"}
       ]},
      {"Done",
       [
         %{text: "Ship the new board", color: "#10b981", label: "Win", tilt: "-0.8deg"},
         %{text: "Invite the team", color: "#ef4444", label: "Urgent", tilt: "1.2deg"}
       ]}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} return_to={~p"/"}>
      <div class="mx-auto w-full max-w-6xl px-4 py-12 sm:px-6 sm:py-16">
        <section class="grid items-center gap-12 lg:grid-cols-[1.05fr_1fr]">
          <div class="text-center lg:text-left">
            <p
              class="h-rise h-glass inline-flex items-center gap-2 rounded-full px-3 py-1 text-xs font-semibold"
              style="--i: 0"
            >
              <span class="h-live-dot"></span> Live for everyone, no sign-up
            </p>
            <h1
              class="h-rise font-display mt-6 text-5xl leading-[1.02] font-extrabold sm:text-7xl"
              style="--i: 1"
            >
              Gather round. <span class="text-glow">Plan it live.</span>
            </h1>
            <p
              class="h-rise text-muted mx-auto mt-5 max-w-xl text-base sm:text-lg lg:mx-0"
              style="--i: 2"
            >
              A shared board where every card, cursor and chat message shows up on
              everyone's screen the moment it happens. Make a board, share the link,
              and you're in a huddle.
            </p>

            <.form
              for={@form}
              id="new-board-form"
              phx-change="validate"
              phx-submit="create"
              class="h-rise mx-auto mt-8 flex max-w-md items-start gap-2 text-left lg:mx-0"
              style="--i: 3"
            >
              <div class="flex-1">
                <.input
                  field={@form[:name]}
                  type="text"
                  placeholder="Name your board, e.g. Sprint 12"
                  autocomplete="off"
                  class="h-input h-input-lg"
                  error_class="h-input-error"
                />
              </div>
              <button
                type="submit"
                id="create-board"
                phx-disable-with="Creating…"
                class="h-btn h-btn-primary h-btn-lg group"
              >
                Create board
                <.icon
                  name="hero-arrow-right-micro"
                  class="size-4 transition-transform group-hover:translate-x-1"
                />
              </button>
            </.form>
          </div>

          <div
            id="hero-demo"
            aria-hidden="true"
            class="h-rise h-glass relative hidden rounded-[2rem] p-4 shadow-2xl shadow-primary/10 sm:block"
            style="--i: 4"
          >
            <div class="mb-3 flex items-center gap-1.5 px-1">
              <span class="size-2.5 rounded-full bg-error/70"></span>
              <span class="size-2.5 rounded-full bg-warning/70"></span>
              <span class="size-2.5 rounded-full bg-success/70"></span>
              <span class="text-muted ml-2 text-xs font-semibold">Launch plan</span>
              <span class="flex-1"></span>
              <span class="flex -space-x-1.5">
                <Layouts.avatar
                  name="Ada"
                  color="#f59e0b"
                  class="size-5 text-[8px] ring-2 ring-base-100"
                />
                <Layouts.avatar
                  name="Grace"
                  color="#ec4899"
                  class="size-5 text-[8px] ring-2 ring-base-100"
                />
                <Layouts.avatar
                  name="Linus"
                  color="#8b5cf6"
                  class="size-5 text-[8px] ring-2 ring-base-100"
                />
              </span>
            </div>
            <div class="h-dots grid grid-cols-3 gap-2.5 rounded-2xl p-2.5">
              <div
                :for={{{title, cards}, column_index} <- Enum.with_index(demo_columns())}
                class="space-y-2 rounded-xl bg-[var(--soft)] p-2"
              >
                <p class="font-display px-1 text-[11px] font-bold">{title}</p>
                <div
                  :for={{card, card_index} <- Enum.with_index(cards)}
                  class="h-demo-card h-card p-2"
                  data-label={card.label}
                  style={"--tint: #{card.color}; --r: #{card.tilt}; --i: #{column_index * 2 + card_index}"}
                >
                  <span class="h-label">{card.label}</span>
                  <p class="mt-1 text-[11px] leading-snug">{card.text}</p>
                </div>
              </div>
            </div>

            <div class="pointer-events-none absolute inset-0">
              <div class="h-demo-cursor absolute inset-0">
                <span class="inline-flex items-start">
                  <.icon name="hero-cursor-arrow-rays-solid" class="size-5 text-[#ec4899]" />
                  <span class="mt-3 rounded-full bg-[#ec4899] px-2 py-0.5 text-[10px] font-bold text-white">
                    Grace
                  </span>
                </span>
              </div>
              <div class="h-demo-cursor is-second absolute inset-0">
                <span class="inline-flex items-start">
                  <.icon name="hero-cursor-arrow-rays-solid" class="size-5 text-[#8b5cf6]" />
                  <span class="mt-3 rounded-full bg-[#8b5cf6] px-2 py-0.5 text-[10px] font-bold text-white">
                    Linus
                  </span>
                </span>
              </div>
            </div>
          </div>
        </section>

        <section class="mt-20">
          <h2 class="font-display text-xl font-bold">Your boards</h2>
          <p
            :if={@boards == []}
            id="boards-empty"
            class="text-muted mt-4 rounded-3xl border border-dashed border-[var(--line)] p-8 text-center text-sm"
          >
            Boards you create or open will show up here.
          </p>
          <ul id="boards" class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <li
              :for={
                {%{board: board, card_count: card_count, read_only: read_only}, index} <-
                  Enum.with_index(@boards)
              }
              id={"board-#{board.id}"}
              class="h-rise"
              style={"--i: #{index}"}
            >
              <.link
                navigate={if read_only, do: ~p"/v/#{board.view_slug}", else: ~p"/b/#{board.slug}"}
                class="h-tile h-glass group flex items-center gap-3 rounded-2xl p-4"
              >
                <span class="grid size-11 shrink-0 place-items-center rounded-xl bg-linear-to-br from-primary/25 to-accent/25 text-primary">
                  <.icon name="hero-view-columns" class="size-5" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="font-display block truncate text-sm font-bold">{board.name}</span>
                  <span class="text-muted flex items-center gap-1.5 text-xs">
                    {card_count} {if card_count == 1, do: "card", else: "cards"}
                    <span :if={read_only} class="inline-flex items-center gap-0.5 text-info">
                      <.icon name="hero-eye-micro" class="size-3" /> view only
                    </span>
                  </span>
                </span>
                <.icon
                  name="hero-arrow-right-micro"
                  class="text-muted size-4 transition group-hover:translate-x-1 group-hover:text-primary"
                />
              </.link>
            </li>
          </ul>
        </section>

        <section class="mt-20">
          <h2 class="font-display text-xl font-bold">Everything a huddle needs</h2>
          <div class="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <div
              :for={{feature, index} <- Enum.with_index(features())}
              class="h-rise h-tile h-glass rounded-3xl p-5"
              style={"--i: #{index}"}
            >
              <span class="grid size-10 place-items-center rounded-xl bg-linear-to-br from-primary to-accent text-primary-content shadow-lg shadow-primary/25">
                <.icon name={feature.icon} class="size-5" />
              </span>
              <h3 class="font-display mt-4 text-base font-bold">{feature.title}</h3>
              <p class="text-muted mt-1 text-sm">{feature.text}</p>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
