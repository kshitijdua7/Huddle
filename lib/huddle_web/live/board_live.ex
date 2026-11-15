defmodule HuddleWeb.BoardLive do
  @moduledoc """
  A single board: columns of cards, who is online, live cursors, a shared
  timer and chat.

  Every browser on the board runs its own copy of this LiveView process. They
  stay in sync by subscribing to the board's PubSub topic:

    * `{:board_changed, id}`: a card or column changed, so reload the board
    * `{:new_message, message}`: append a chat message
    * `{:cursor, payload}` and `{:typing, user}`: short-lived signals that are
      relayed straight to the browser and never touch the database
    * timer messages from `Huddle.BoardServer`
    * `presence_diff`: someone joined or left
  """
  use HuddleWeb, :live_view

  alias Huddle.{BoardServer, Boards, Chat}
  alias HuddleWeb.Presence
  alias Phoenix.Socket.Broadcast

  @typing_ttl 3_000
  @max_avatars 6

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Boards.get_board_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That board doesn't exist.")
         |> redirect(to: ~p"/")}

      board ->
        if connected?(socket), do: join(board, socket.assigns.current_user)

        {:ok,
         socket
         |> assign(:page_title, board.name)
         |> assign_board(board)
         |> assign(:users, list_users(board))
         |> assign(:typing, %{})
         |> assign(:timer_ends_at, BoardServer.timer(board.id))
         |> stream(:messages, Chat.list_messages(board))}
    end
  end

  defp join(board, user) do
    Boards.subscribe(board)
    Phoenix.PubSub.subscribe(Huddle.PubSub, presence_topic(board))

    {:ok, _ref} =
      Presence.track(self(), presence_topic(board), user["id"], %{
        name: user["name"],
        color: user["color"],
        joined_at: System.system_time(:millisecond)
      })
  end

  ## Events from this browser

  @impl true
  def handle_event("add_card", %{"column_id" => column_id, "title" => title}, socket) do
    with %{} = column <- Boards.get_column(socket.assigns.board, column_id) do
      Boards.create_card(column, socket.assigns.current_user, %{"title" => title})
    end

    {:noreply, socket}
  end

  def handle_event("delete_card", %{"id" => id}, socket) do
    with %{} = card <- Boards.get_card(socket.assigns.board, id) do
      Boards.delete_card(card)
    end

    {:noreply, socket}
  end

  def handle_event("vote_card", %{"id" => id}, socket) do
    with %{} = card <- Boards.get_card(socket.assigns.board, id) do
      Boards.vote_card(card)
    end

    {:noreply, socket}
  end

  def handle_event("move_card", %{"id" => id, "column_id" => column_id} = params, socket) do
    %{board: board, current_user: user} = socket.assigns

    with %{} = card <- Boards.get_card(board, id),
         %{} = column <- Boards.get_column(board, column_id),
         {:ok, _card} <- Boards.move_card(card, column.id, to_integer(params["index"])) do
      if card.column_id != column.id do
        Chat.create_system_message(
          board,
          "#{user["name"]} moved “#{card.title}” to #{column.title}"
        )
      end
    end

    {:noreply, socket}
  end

  def handle_event("add_column", %{"title" => title}, socket) do
    Boards.create_column(socket.assigns.board, %{"title" => title})
    {:noreply, socket}
  end

  def handle_event("delete_column", %{"id" => id}, socket) do
    with %{} = column <- Boards.get_column(socket.assigns.board, id) do
      Boards.delete_column(column)
    end

    {:noreply, socket}
  end

  def handle_event("send_message", %{"body" => body}, socket) do
    Chat.create_message(socket.assigns.board, socket.assigns.current_user, %{"body" => body})
    {:noreply, socket}
  end

  def handle_event("typing", _params, socket) do
    user = socket.assigns.current_user
    broadcast_from_self(socket, {:typing, %{id: user["id"], name: user["name"]}})
    {:noreply, socket}
  end

  def handle_event("cursor", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    user = socket.assigns.current_user

    broadcast_from_self(
      socket,
      {:cursor,
       %{id: user["id"], name: user["name"], color: user["color"], x: clamp(x), y: clamp(y)}}
    )

    {:noreply, socket}
  end

  def handle_event("start_timer", %{"minutes" => minutes}, socket) when minutes in ~w(1 5 10) do
    %{board: board, current_user: user} = socket.assigns

    {:ok, _ends_at} = BoardServer.start_timer(board.id, String.to_integer(minutes) * 60_000)
    Chat.create_system_message(board, "#{user["name"]} started a #{minutes}-minute timer")

    {:noreply, socket}
  end

  def handle_event("stop_timer", _params, socket) do
    BoardServer.stop_timer(socket.assigns.board.id)
    {:noreply, socket}
  end

  # Anything malformed (for example a hand-crafted payload) is ignored.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## Messages from other processes

  @impl true
  def handle_info({:board_changed, _board_id}, socket) do
    case Boards.get_board_by_slug(socket.assigns.board.slug) do
      nil -> {:noreply, redirect(socket, to: ~p"/")}
      board -> {:noreply, assign_board(socket, board)}
    end
  end

  def handle_info({:new_message, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  def handle_info({:cursor, payload}, socket) do
    {:noreply, push_event(socket, "cursor", payload)}
  end

  def handle_info({:typing, %{id: id, name: name}}, socket) do
    ref = make_ref()
    Process.send_after(self(), {:typing_expired, id, ref}, @typing_ttl)
    {:noreply, update(socket, :typing, &Map.put(&1, id, {name, ref}))}
  end

  def handle_info({:typing_expired, id, ref}, socket) do
    typing =
      case socket.assigns.typing do
        %{^id => {_name, ^ref}} = typing -> Map.delete(typing, id)
        typing -> typing
      end

    {:noreply, assign(socket, :typing, typing)}
  end

  def handle_info({:timer_started, ends_at}, socket) do
    {:noreply, assign(socket, :timer_ends_at, ends_at)}
  end

  def handle_info(:timer_stopped, socket) do
    {:noreply, assign(socket, :timer_ends_at, nil)}
  end

  def handle_info(:timer_finished, socket) do
    {:noreply,
     socket
     |> assign(:timer_ends_at, nil)
     |> put_flash(:info, "Time's up!")}
  end

  def handle_info(%Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :users, list_users(socket.assigns.board))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Helpers

  defp assign_board(socket, board) do
    card_count = board.columns |> Enum.map(&length(&1.cards)) |> Enum.sum()

    socket
    |> assign(:board, board)
    |> assign(:card_count, card_count)
  end

  defp presence_topic(board), do: "presence:board:#{board.id}"

  defp list_users(board) do
    board
    |> presence_topic()
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} ->
      %{id: id, name: meta.name, color: meta.color, joined_at: meta.joined_at}
    end)
    |> Enum.sort_by(& &1.joined_at)
  end

  defp broadcast_from_self(socket, message) do
    Phoenix.PubSub.broadcast_from(
      Huddle.PubSub,
      self(),
      Boards.topic(socket.assigns.board.id),
      message
    )
  end

  defp clamp(number), do: number |> max(0) |> min(1)

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp to_integer(_value), do: 0

  defp typing_text(typing) do
    case typing |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sort() do
      [] -> nil
      [name] -> "#{name} is typing…"
      [first, second] -> "#{first} and #{second} are typing…"
      _many -> "Several people are typing…"
    end
  end

  defp visible_users(users), do: Enum.take(users, @max_avatars)

  defp hidden_user_count(users), do: max(length(users) - @max_avatars, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      return_to={~p"/b/#{@board.slug}"}
      fill
    >
      <div class="flex min-h-0 flex-1 flex-col lg:flex-row">
        <section class="flex min-h-0 min-w-0 flex-1 flex-col">
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-base-300 px-4 py-3 sm:px-6">
            <div class="min-w-0 flex-1">
              <h1 id="board-name" class="truncate text-xl font-semibold tracking-tight">
                {@board.name}
              </h1>
              <p class="text-xs text-base-content/60">
                <span id="card-count">{@card_count}</span>
                {if @card_count == 1, do: "card", else: "cards"} · share this page's link to invite people
              </p>
            </div>

            <div
              id="timer"
              phx-hook="Countdown"
              data-ends-at={@timer_ends_at && DateTime.to_iso8601(@timer_ends_at)}
              class="flex items-center gap-1 rounded-full border border-base-300 bg-base-200 px-2 py-1"
            >
              <.icon name="hero-clock-micro" class="size-4 text-base-content/60" />
              <span
                id="timer-display"
                phx-update="ignore"
                class="font-mono text-sm font-semibold tabular-nums"
              >
              </span>
              <%= if @timer_ends_at do %>
                <button
                  type="button"
                  id="stop-timer"
                  phx-click="stop_timer"
                  class="btn btn-ghost btn-xs rounded-full"
                >
                  Stop
                </button>
              <% else %>
                <button
                  :for={minutes <- [1, 5, 10]}
                  type="button"
                  id={"start-timer-#{minutes}"}
                  phx-click="start_timer"
                  phx-value-minutes={minutes}
                  class="btn btn-ghost btn-xs rounded-full"
                >
                  {minutes}m
                </button>
              <% end %>
            </div>

            <div class="flex items-center gap-2">
              <ul id="presence-list" class="flex items-center -space-x-2">
                <li
                  :for={user <- visible_users(@users)}
                  id={"presence-#{user.id}"}
                  data-user-id={user.id}
                  title={user.name}
                >
                  <Layouts.avatar
                    name={user.name}
                    color={user.color}
                    class="size-8 text-xs ring-2 ring-base-100"
                  />
                </li>
                <li
                  :if={hidden_user_count(@users) > 0}
                  id="presence-overflow"
                  class="grid size-8 place-items-center rounded-full bg-base-300 text-xs font-semibold ring-2 ring-base-100"
                >
                  +{hidden_user_count(@users)}
                </li>
              </ul>
              <span id="online-count" class="text-xs text-base-content/60">
                {length(@users)} online
              </span>
            </div>
          </div>

          <div id="board-canvas" class="relative min-h-0 flex-1">
            <div
              id="columns"
              phx-hook="BoardDnD"
              class="flex h-full items-start gap-4 overflow-x-auto p-4 sm:p-6"
            >
              <div
                :for={column <- @board.columns}
                id={"column-#{column.id}"}
                class="group/col flex max-h-full w-72 shrink-0 flex-col rounded-2xl border border-base-300 bg-base-200"
              >
                <div class="flex items-center gap-2 px-4 pt-3 pb-2">
                  <h2 class="min-w-0 flex-1 truncate text-sm font-semibold">{column.title}</h2>
                  <span class="rounded-full bg-base-300 px-2 py-0.5 text-xs tabular-nums">
                    {length(column.cards)}
                  </span>
                  <button
                    type="button"
                    id={"delete-column-#{column.id}"}
                    phx-click="delete_column"
                    phx-value-id={column.id}
                    data-confirm="Delete this column and all of its cards?"
                    aria-label="Delete column"
                    class="btn btn-ghost btn-xs btn-square opacity-0 transition group-hover/col:opacity-100 focus:opacity-100"
                  >
                    <.icon name="hero-trash-micro" class="size-4" />
                  </button>
                </div>

                <div
                  id={"cards-#{column.id}"}
                  data-column-id={column.id}
                  class="flex min-h-16 flex-1 flex-col gap-2 overflow-y-auto px-3 py-1"
                >
                  <article
                    :for={card <- column.cards}
                    id={"card-#{card.id}"}
                    data-card-id={card.id}
                    draggable="true"
                    class="group/card cursor-grab rounded-xl border border-l-4 border-base-300 bg-base-100 p-3 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md active:cursor-grabbing"
                    style={"border-left-color: #{card.author_color}"}
                  >
                    <p class="text-sm leading-snug break-words">{card.title}</p>
                    <div class="mt-2 flex items-center gap-1 text-xs text-base-content/60">
                      <span class="min-w-0 flex-1 truncate">{card.author_name}</span>
                      <button
                        type="button"
                        id={"vote-card-#{card.id}"}
                        phx-click="vote_card"
                        phx-value-id={card.id}
                        aria-label="Vote for this card"
                        class={[
                          "flex items-center gap-1 rounded-full px-2 py-0.5 transition hover:bg-primary/10 hover:text-primary",
                          card.votes > 0 && "bg-primary/10 font-semibold text-primary"
                        ]}
                      >
                        <.icon name="hero-hand-thumb-up-micro" class="size-3.5" />
                        <span>{card.votes}</span>
                      </button>
                      <button
                        type="button"
                        id={"delete-card-#{card.id}"}
                        phx-click="delete_card"
                        phx-value-id={card.id}
                        aria-label="Delete card"
                        class="rounded-full p-1 opacity-0 transition group-hover/card:opacity-100 hover:bg-error/10 hover:text-error focus:opacity-100"
                      >
                        <.icon name="hero-x-mark-micro" class="size-3.5" />
                      </button>
                    </div>
                  </article>
                  <p
                    :if={column.cards == []}
                    class="pointer-events-none rounded-xl border border-dashed border-base-300 px-3 py-4 text-center text-xs text-base-content/50"
                  >
                    Drop a card here
                  </p>
                </div>

                <form
                  id={"add-card-#{column.id}"}
                  phx-submit="add_card"
                  phx-hook="ResetOnSubmit"
                  class="p-3 pt-2"
                >
                  <input type="hidden" name="column_id" value={column.id} />
                  <input
                    type="text"
                    name="title"
                    placeholder="+ Add a card"
                    maxlength="140"
                    autocomplete="off"
                    required
                    class="input input-sm w-full border-transparent bg-transparent focus:border-primary focus:bg-base-100"
                  />
                </form>
              </div>

              <form
                id="add-column-form"
                phx-submit="add_column"
                phx-hook="ResetOnSubmit"
                class="w-72 shrink-0 rounded-2xl border border-dashed border-base-300 p-3"
              >
                <input
                  type="text"
                  name="title"
                  placeholder="+ Add a column"
                  maxlength="40"
                  autocomplete="off"
                  required
                  class="input input-sm w-full border-transparent bg-transparent focus:border-primary focus:bg-base-100"
                />
              </form>
            </div>

            <div
              id="cursor-layer"
              phx-hook="Cursors"
              phx-update="ignore"
              class="pointer-events-none absolute inset-0 z-30 overflow-hidden"
            >
            </div>
          </div>
        </section>

        <aside
          id="chat"
          class="flex h-72 shrink-0 flex-col border-t border-base-300 lg:h-auto lg:w-80 lg:border-t-0 lg:border-l"
        >
          <div class="flex items-center gap-2 border-b border-base-300 px-4 py-3">
            <.icon name="hero-chat-bubble-left-right-micro" class="size-4 text-primary" />
            <h2 class="text-sm font-semibold">Chat &amp; activity</h2>
          </div>

          <div
            id="messages"
            phx-update="stream"
            phx-hook="ChatScroll"
            class="min-h-0 flex-1 overflow-y-auto py-2"
          >
            <p
              id="messages-empty"
              class="hidden px-4 py-8 text-center text-xs text-base-content/50 only:block"
            >
              No messages yet. Say hi!
            </p>
            <div :for={{dom_id, message} <- @streams.messages} id={dom_id} class="px-4 py-1.5">
              <%= if message.kind == "system" do %>
                <p class="text-center text-xs text-base-content/50">{message.body}</p>
              <% else %>
                <div class="flex items-start gap-2">
                  <Layouts.avatar
                    name={message.author_name}
                    color={message.author_color}
                    class="mt-0.5 size-6 text-[10px]"
                  />
                  <div class="min-w-0">
                    <p class="text-xs font-semibold" style={"color: #{message.author_color}"}>
                      {message.author_name}
                    </p>
                    <p class="text-sm break-words whitespace-pre-wrap">{message.body}</p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <p id="typing-indicator" class="h-5 px-4 text-xs text-base-content/60 italic">
            {typing_text(@typing)}
          </p>

          <form
            id="chat-form"
            phx-submit="send_message"
            phx-change="typing"
            phx-hook="ResetOnSubmit"
            class="flex gap-2 border-t border-base-300 p-3"
          >
            <input
              id="chat-input"
              type="text"
              name="body"
              placeholder="Message everyone here"
              maxlength="1000"
              autocomplete="off"
              phx-throttle="1500"
              class="input input-sm min-w-0 flex-1"
            />
            <button type="submit" class="btn btn-primary btn-sm btn-square" aria-label="Send">
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </button>
          </form>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
