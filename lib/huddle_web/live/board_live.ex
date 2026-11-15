defmodule HuddleWeb.BoardLive do
  @moduledoc """
  A single board: columns of cards, who is online, live cursors, a shared
  timer, chat, and the tools around them (sharing, search, labels, reactions,
  anonymous voting, presenting and export).

  The same LiveView serves two links to a board:

    * `/b/:slug` can edit
    * `/v/:view_slug` is read-only: every event that would change something
      is ignored on the server, not just hidden in the page

  Every browser on the board runs its own copy of this LiveView process. They
  stay in sync by subscribing to the board's PubSub topic:

    * `{:board_changed, id}`: a card or column changed, so reload the board
    * `{:new_message, message}` and `{:message_updated, message}`: chat
    * `{:cursor, payload}`, `{:typing, user}`, `{:present_scroll, x}` and
      `{:spotlight, card_id}`: short-lived signals that are relayed straight
      to the browser and never touch the database
    * timer and presenter messages from `Huddle.BoardServer`
    * `presence_diff`: someone joined or left
  """
  use HuddleWeb, :live_view

  alias Huddle.{BoardServer, Boards, Chat, QR, Reactions}
  alias HuddleWeb.Presence
  alias Phoenix.Socket.Broadcast

  @typing_ttl 3_000
  @max_avatars 6

  # What someone on the read-only link may still do: none of it changes the board.
  @viewer_events ~w(search filter_label clear_filters open_share close_share toggle_follow cursor)

  @labels [
    %{id: "idea", name: "Idea", color: "#f59e0b", icon: "hero-light-bulb-micro"},
    %{id: "bug", name: "Bug", color: "#a855f7", icon: "hero-bug-ant-micro"},
    %{id: "urgent", name: "Urgent", color: "#ef4444", icon: "hero-fire-micro"},
    %{
      id: "question",
      name: "Question",
      color: "#0ea5e9",
      icon: "hero-question-mark-circle-micro"
    },
    %{id: "win", name: "Win", color: "#10b981", icon: "hero-trophy-micro"}
  ]

  @impl true
  def mount(params, _session, socket) do
    {board, read_only} =
      case socket.assigns.live_action do
        :view -> {Boards.get_board_by_view_slug(params["view_slug"]), true}
        _edit -> {Boards.get_board_by_slug(params["slug"]), false}
      end

    case board do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That board doesn't exist.")
         |> redirect(to: ~p"/")}

      board ->
        if connected?(socket), do: join(board, socket.assigns.current_user, read_only)

        {:ok,
         socket
         |> assign(:page_title, board.name)
         |> assign(:read_only, read_only)
         |> assign_board(board)
         |> assign(:users, list_users(board))
         |> assign(:typing, %{})
         |> assign(:timer_ends_at, BoardServer.timer(board.id))
         |> assign(:presenter, BoardServer.presenter(board.id))
         |> assign(:following, true)
         |> assign(:spotlight_card_id, nil)
         |> assign(:query, "")
         |> assign(:label_filter, nil)
         |> assign(:edit, nil)
         |> assign(:editing_column_id, nil)
         |> assign(:share_open, false)
         |> assign(:share_kind, if(read_only, do: "view", else: "edit"))
         |> assign(:qr, %{})
         |> assign(:origin, "")
         |> stream(:messages, Chat.list_messages(board))}
    end
  end

  # The address the visitor actually used, so shared links and QR codes point
  # at the same host whether that is localhost, a LAN address or a domain.
  @impl true
  def handle_params(_params, uri, socket) do
    origin = uri |> URI.parse() |> Map.merge(%{path: nil, query: nil, fragment: nil})
    {:noreply, assign(socket, :origin, URI.to_string(origin))}
  end

  defp join(board, user, read_only) do
    Boards.subscribe(board)
    Phoenix.PubSub.subscribe(Huddle.PubSub, presence_topic(board))
    Boards.record_visit(board, user["id"], read_only)

    {:ok, _ref} =
      Presence.track(self(), presence_topic(board), user["id"], %{
        name: user["name"],
        color: user["color"],
        viewer: read_only,
        joined_at: System.system_time(:millisecond)
      })
  end

  ## Events from this browser

  @impl true
  def handle_event(event, _params, %{assigns: %{read_only: true}} = socket)
      when event not in @viewer_events do
    {:noreply, socket}
  end

  # Cards

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

  def handle_event("react_card", %{"id" => id, "emoji" => emoji}, socket) do
    with %{} = card <- Boards.get_card(socket.assigns.board, id) do
      Boards.toggle_card_reaction(card, socket.assigns.current_user["id"], emoji)
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

  def handle_event("edit_card", %{"id" => id}, socket) do
    case Boards.get_card(socket.assigns.board, id) do
      nil -> {:noreply, socket}
      card -> {:noreply, assign(socket, :edit, %{id: card.id, form: card_form(card, %{})})}
    end
  end

  def handle_event("edit_change", %{"card" => params}, %{assigns: %{edit: %{id: id}}} = socket) do
    case Boards.get_card(socket.assigns.board, id) do
      nil -> {:noreply, assign(socket, :edit, nil)}
      card -> {:noreply, assign(socket, :edit, %{id: id, form: card_form(card, params)})}
    end
  end

  def handle_event("save_card", %{"card" => params}, %{assigns: %{edit: %{id: id}}} = socket) do
    with %{} = card <- Boards.get_card(socket.assigns.board, id),
         {:error, %Ecto.Changeset{}} <- Boards.update_card(card, params) do
      {:noreply, assign(socket, :edit, %{id: id, form: card_form(card, params)})}
    else
      _saved_or_gone -> {:noreply, assign(socket, :edit, nil)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :edit, nil)}
  end

  # Columns

  def handle_event("add_column", %{"title" => title}, socket) do
    Boards.create_column(socket.assigns.board, %{"title" => title})
    {:noreply, socket}
  end

  def handle_event("edit_column", %{"id" => id}, socket) do
    case Boards.get_column(socket.assigns.board, id) do
      nil -> {:noreply, socket}
      column -> {:noreply, assign(socket, :editing_column_id, column.id)}
    end
  end

  # Sent with "column_id" and "title" when the form is submitted, and with
  # "id" and "value" when the field loses focus.
  def handle_event("rename_column", params, socket) do
    id = params["column_id"] || params["id"]
    title = params["title"] || params["value"] || ""

    with true <- socket.assigns.editing_column_id != nil,
         %{} = column <- Boards.get_column(socket.assigns.board, id) do
      Boards.update_column(column, %{"title" => title})
    end

    {:noreply, assign(socket, :editing_column_id, nil)}
  end

  def handle_event("cancel_column_edit", _params, socket) do
    {:noreply, assign(socket, :editing_column_id, nil)}
  end

  def handle_event("delete_column", %{"id" => id}, socket) do
    with %{} = column <- Boards.get_column(socket.assigns.board, id) do
      Boards.delete_column(column)
    end

    {:noreply, socket}
  end

  # Chat

  def handle_event("send_message", %{"body" => body}, socket) do
    Chat.create_message(socket.assigns.board, socket.assigns.current_user, %{"body" => body})
    {:noreply, socket}
  end

  def handle_event("react_message", %{"id" => id, "emoji" => emoji}, socket) do
    with %{} = message <- Chat.get_message(socket.assigns.board, id) do
      Chat.toggle_reaction(message, socket.assigns.current_user["id"], emoji)
    end

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

  # Timer and voting

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

  def handle_event("toggle_votes", _params, socket) do
    %{board: board, current_user: user} = socket.assigns
    hidden? = !board.votes_hidden

    with {:ok, _board} <- Boards.set_votes_hidden(board, hidden?) do
      action = if hidden?, do: "hid the votes", else: "revealed the votes"
      Chat.create_system_message(board, "#{user["name"]} #{action}")
    end

    {:noreply, socket}
  end

  # Presenting

  def handle_event("start_presenting", _params, socket) do
    %{board: board, current_user: user} = socket.assigns
    presenter = %{id: user["id"], name: user["name"], color: user["color"]}

    BoardServer.start_presenting(board.id, presenter, self())
    Chat.create_system_message(board, "#{user["name"]} started presenting")

    {:noreply, socket}
  end

  def handle_event("stop_presenting", _params, socket) do
    BoardServer.stop_presenting(socket.assigns.board.id, socket.assigns.current_user["id"])
    {:noreply, socket}
  end

  def handle_event("toggle_follow", _params, socket) do
    {:noreply, update(socket, :following, &(!&1))}
  end

  def handle_event("present_scroll", %{"x" => x}, socket) when is_number(x) do
    if presenting?(socket.assigns), do: broadcast_from_self(socket, {:present_scroll, clamp(x)})
    {:noreply, socket}
  end

  def handle_event("spotlight", %{"id" => id}, socket) do
    with true <- presenting?(socket.assigns),
         %{} = card <- Boards.get_card(socket.assigns.board, id) do
      Phoenix.PubSub.broadcast(
        Huddle.PubSub,
        Boards.topic(socket.assigns.board.id),
        {:spotlight, card.id}
      )
    end

    {:noreply, socket}
  end

  # Search, filters and sharing: these only change this browser's view

  def handle_event("search", %{"q" => query}, socket) when is_binary(query) do
    {:noreply, assign(socket, :query, query |> String.trim() |> String.downcase())}
  end

  def handle_event("filter_label", %{"label" => label}, socket) do
    label = if label == socket.assigns.label_filter, do: nil, else: label
    {:noreply, assign(socket, :label_filter, if(label_for(label), do: label))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:query, "") |> assign(:label_filter, nil)}
  end

  def handle_event("open_share", _params, socket) do
    qr =
      for {kind, url} <- share_urls(socket.assigns), into: %{} do
        case QR.encode(url) do
          {:ok, rows} -> {kind, QR.svg(rows)}
          :error -> {kind, nil}
        end
      end

    {:noreply, socket |> assign(:qr, qr) |> assign(:share_open, true)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, socket |> assign(:share_open, false) |> assign(:qr, %{})}
  end

  def handle_event("share_kind", %{"kind" => kind}, socket) when kind in ~w(edit view) do
    {:noreply, assign(socket, :share_kind, kind)}
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

  def handle_info({:message_updated, message}, socket) do
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
     |> put_flash(:info, "Time's up!")
     |> push_event("confetti", %{})}
  end

  def handle_info({:presenter_changed, presenter}, socket) do
    {:noreply,
     socket
     |> assign(:presenter, presenter)
     |> assign(:following, true)
     |> assign(:spotlight_card_id, nil)}
  end

  def handle_info({:present_scroll, x}, socket) do
    if following?(socket.assigns) do
      {:noreply, push_event(socket, "follow_scroll", %{x: x})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:spotlight, card_id}, socket) do
    socket = assign(socket, :spotlight_card_id, card_id)

    if following?(socket.assigns) do
      {:noreply, push_event(socket, "spotlight", %{id: card_id})}
    else
      {:noreply, socket}
    end
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

  defp card_form(card, params) do
    card
    |> Boards.change_card(params)
    |> to_form(as: :card, action: if(params == %{}, do: nil, else: :validate))
  end

  defp presence_topic(board), do: "presence:board:#{board.id}"

  defp list_users(board) do
    board
    |> presence_topic()
    |> Presence.list()
    |> Enum.map(fn {id, %{metas: [meta | _]}} ->
      %{
        id: id,
        name: meta.name,
        color: meta.color,
        viewer: Map.get(meta, :viewer, false),
        joined_at: meta.joined_at
      }
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

  defp presenting?(%{presenter: %{id: id}, current_user: %{"id" => id}}), do: true
  defp presenting?(_assigns), do: false

  # Following means someone else is presenting and this visitor has not opted out.
  defp following?(%{presenter: nil}), do: false
  defp following?(assigns), do: assigns.following and not presenting?(assigns)

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

  defp labels, do: @labels

  defp label_for(nil), do: nil
  defp label_for(id), do: Enum.find(@labels, &(&1.id == id))

  defp filtering?(assigns), do: assigns.query != "" or assigns.label_filter != nil

  defp card_visible?(card, query, label_filter) do
    (label_filter == nil or card.label == label_filter) and
      (query == "" or String.contains?(String.downcase(card.title), query))
  end

  defp board_path(board, true), do: ~p"/v/#{board.view_slug}"
  defp board_path(board, false), do: ~p"/b/#{board.slug}"

  defp export_path(board, true, format), do: ~p"/v/#{board.view_slug}/export/#{format}"
  defp export_path(board, false, format), do: ~p"/b/#{board.slug}/export/#{format}"

  # The links this visitor may hand out. Someone on the read-only link never
  # receives the edit link.
  defp share_urls(%{board: board, origin: origin, read_only: read_only}) do
    view = %{"view" => origin <> ~p"/v/#{board.view_slug}"}
    if read_only, do: view, else: Map.put(view, "edit", origin <> ~p"/b/#{board.slug}")
  end

  defp local_origin?(origin) do
    URI.parse(origin).host in ["localhost", "127.0.0.1", "::1"]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      return_to={board_path(@board, @read_only)}
      fill
    >
      <div class="flex min-h-0 flex-1 flex-col lg:flex-row">
        <section class="flex min-h-0 min-w-0 flex-1 flex-col">
          <.presenter_banner
            presenter={@presenter}
            presenting={presenting?(assigns)}
            following={@following}
          />

          <div class="flex flex-wrap items-center gap-x-4 gap-y-3 px-4 pt-4 sm:px-6">
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <h1 id="board-name" class="font-display truncate text-2xl font-bold">
                  {@board.name}
                </h1>
                <span
                  :if={@read_only}
                  id="read-only-badge"
                  class="inline-flex shrink-0 items-center gap-1 rounded-full bg-info/15 px-2 py-0.5 text-[11px] font-semibold text-info"
                >
                  <.icon name="hero-eye-micro" class="size-3.5" /> View only
                </span>
              </div>
              <p class="text-muted mt-0.5 flex items-center gap-2 text-xs">
                <span>
                  <span id="card-count">{@card_count}</span>
                  {if @card_count == 1, do: "card", else: "cards"}
                </span>
                <span class="h-live-dot"></span>
                <span id="online-count">{length(@users)} online</span>
              </p>
            </div>

            <div
              id="timer"
              phx-hook="Countdown"
              data-ends-at={@timer_ends_at && DateTime.to_iso8601(@timer_ends_at)}
              class={[
                "h-glass flex h-9 items-center gap-1 rounded-full px-2",
                @read_only && !@timer_ends_at && "hidden"
              ]}
            >
              <.icon name="hero-clock-micro" class="text-muted size-4" />
              <span
                id="timer-display"
                phx-update="ignore"
                class="font-mono text-sm font-bold tabular-nums"
              ></span>
              <%= cond do %>
                <% @read_only -> %>
                <% @timer_ends_at -> %>
                  <button
                    type="button"
                    id="stop-timer"
                    phx-click="stop_timer"
                    class="h-btn h-btn-ghost h-btn-sm"
                  >
                    Stop
                  </button>
                <% true -> %>
                  <button
                    :for={minutes <- [1, 5, 10]}
                    type="button"
                    id={"start-timer-#{minutes}"}
                    phx-click="start_timer"
                    phx-value-minutes={minutes}
                    class="h-btn h-btn-ghost h-btn-sm"
                  >
                    {minutes}m
                  </button>
              <% end %>
            </div>

            <ul id="presence-list" class="flex items-center -space-x-2">
              <li
                :for={user <- visible_users(@users)}
                id={"presence-#{user.id}"}
                data-user-id={user.id}
                title={if user.viewer, do: "#{user.name} (viewing)", else: user.name}
                class="h-avatar-in transition-transform duration-200 hover:z-10 hover:-translate-y-1"
              >
                <Layouts.avatar
                  name={user.name}
                  color={user.color}
                  class={[
                    "size-8 text-xs ring-2 ring-base-200",
                    user.viewer && "opacity-60"
                  ]}
                />
              </li>
              <li
                :if={hidden_user_count(@users) > 0}
                id="presence-overflow"
                class="grid size-8 place-items-center rounded-full bg-base-300 text-xs font-semibold ring-2 ring-base-200"
              >
                +{hidden_user_count(@users)}
              </li>
            </ul>

            <button type="button" id="share-button" phx-click="open_share" class="h-btn h-btn-primary">
              <.icon name="hero-user-plus-micro" class="size-4" /> Share
            </button>
          </div>

          <div class="flex flex-wrap items-center gap-2 px-4 py-3 sm:px-6">
            <form
              id="search-form"
              phx-change="search"
              phx-submit="search"
              class="relative w-full sm:w-52"
            >
              <.icon
                name="hero-magnifying-glass-micro"
                class="text-muted pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2"
              />
              <input
                id="search-input"
                type="search"
                name="q"
                value={@query}
                placeholder="Search cards"
                autocomplete="off"
                phx-debounce="120"
                class="h-input pl-9"
              />
            </form>

            <div id="label-filters" class="flex flex-wrap items-center gap-1.5">
              <button
                :for={label <- labels()}
                type="button"
                id={"filter-#{label.id}"}
                phx-click="filter_label"
                phx-value-label={label.id}
                aria-pressed={to_string(@label_filter == label.id)}
                class={["h-chip", @label_filter == label.id && "is-on"]}
                style={"--tint: #{label.color}"}
              >
                <span class="h-chip-dot"></span>{label.name}
              </button>
              <button
                :if={filtering?(assigns)}
                type="button"
                id="clear-filters"
                phx-click="clear_filters"
                class="h-chip h-pop"
              >
                <.icon name="hero-x-mark-micro" class="size-3.5" /> Clear
              </button>
            </div>

            <div class="flex-1"></div>

            <button
              :if={!@read_only}
              type="button"
              id="toggle-votes"
              phx-click="toggle_votes"
              class={["h-btn h-btn-soft", @board.votes_hidden && "is-on"]}
            >
              <.icon
                name={if @board.votes_hidden, do: "hero-eye-micro", else: "hero-eye-slash-micro"}
                class="size-4"
              />
              {if @board.votes_hidden, do: "Reveal votes", else: "Hide votes"}
            </button>

            <button
              :if={!@read_only}
              type="button"
              id="present-toggle"
              phx-click={if presenting?(assigns), do: "stop_presenting", else: "start_presenting"}
              class={["h-btn h-btn-soft", presenting?(assigns) && "is-on"]}
            >
              <.icon name="hero-presentation-chart-bar-micro" class="size-4" />
              {if presenting?(assigns), do: "Stop presenting", else: "Present"}
            </button>

            <div class="relative">
              <button
                type="button"
                id="export-button"
                phx-click={JS.toggle(to: "#export-menu")}
                class="h-btn h-btn-soft"
              >
                <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Export
              </button>
              <div
                id="export-menu"
                phx-click-away={JS.hide(to: "#export-menu")}
                class="h-menu h-glass absolute right-0 z-40 mt-2 hidden w-48 rounded-2xl !bg-base-100 p-1.5 shadow-2xl"
              >
                <a
                  id="export-markdown"
                  href={export_path(@board, @read_only, "md")}
                  download
                  class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm transition hover:bg-[var(--soft)]"
                >
                  <.icon name="hero-document-text-micro" class="text-muted size-4" /> Markdown
                </a>
                <a
                  id="export-csv"
                  href={export_path(@board, @read_only, "csv")}
                  download
                  class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm transition hover:bg-[var(--soft)]"
                >
                  <.icon name="hero-table-cells-micro" class="text-muted size-4" /> CSV spreadsheet
                </a>
              </div>
            </div>
          </div>

          <div id="board-canvas" class="h-dots relative min-h-0 flex-1 border-t border-[var(--line)]">
            <div
              id="columns"
              phx-hook="Board"
              data-read-only={to_string(@read_only)}
              data-presenting={to_string(presenting?(assigns))}
              class="flex h-full items-start gap-4 overflow-x-auto p-4 sm:p-6"
            >
              <div
                :for={column <- @board.columns}
                id={"column-#{column.id}"}
                class="h-column h-glass group/col flex max-h-full w-72 shrink-0 flex-col"
              >
                <.column_header
                  column={column}
                  editing={@editing_column_id == column.id}
                  read_only={@read_only}
                  visible_count={Enum.count(column.cards, &card_visible?(&1, @query, @label_filter))}
                  filtering={filtering?(assigns)}
                />

                <div
                  id={"cards-#{column.id}"}
                  data-column-id={column.id}
                  class="flex min-h-16 flex-1 flex-col gap-2 overflow-y-auto px-3 py-1 transition-colors"
                >
                  <article
                    :for={{card, index} <- Enum.with_index(column.cards)}
                    id={"card-#{card.id}"}
                    data-card-id={card.id}
                    data-label={card.label}
                    draggable={if(!@read_only and !(@edit && @edit.id == card.id), do: "true")}
                    class={[
                      "h-card group/card shrink-0 p-3",
                      @edit && @edit.id == card.id && "is-editing",
                      @spotlight_card_id == card.id && "is-spotlight",
                      !card_visible?(card, @query, @label_filter) && "hidden"
                    ]}
                    style={"--i: #{min(index, 10)}; --tint: #{(label_for(card.label) || %{color: "transparent"}).color}"}
                  >
                    <%= if @edit && @edit.id == card.id do %>
                      <.card_editor card={card} form={@edit.form} />
                    <% else %>
                      <.card_body
                        card={card}
                        read_only={@read_only}
                        votes_hidden={@board.votes_hidden}
                        user_id={@current_user["id"]}
                      />
                    <% end %>
                  </article>
                  <p
                    :if={column.cards == []}
                    class="text-muted pointer-events-none rounded-xl border border-dashed border-[var(--line)] px-3 py-4 text-center text-xs"
                  >
                    {if @read_only, do: "Nothing here yet", else: "Drop a card here"}
                  </p>
                </div>

                <form
                  :if={!@read_only}
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
                    class="h-input h-input-bare"
                  />
                </form>
                <div :if={@read_only} class="h-3"></div>
              </div>

              <form
                :if={!@read_only}
                id="add-column-form"
                phx-submit="add_column"
                phx-hook="ResetOnSubmit"
                class="w-72 shrink-0 rounded-[1.25rem] border border-dashed border-[var(--line)] p-3 transition-colors focus-within:border-primary hover:border-primary/60"
              >
                <input
                  type="text"
                  name="title"
                  placeholder="+ Add a column"
                  maxlength="40"
                  autocomplete="off"
                  required
                  class="h-input h-input-bare"
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
          class="h-glass flex h-72 shrink-0 flex-col border-x-0 border-b-0 lg:h-auto lg:w-80 lg:border-t-0 lg:border-l"
        >
          <div class="flex items-center gap-2 border-b border-[var(--line)] px-4 py-3">
            <.icon name="hero-chat-bubble-left-right-micro" class="size-4 text-primary" />
            <h2 class="font-display text-sm font-bold">Chat &amp; activity</h2>
          </div>

          <div
            id="messages"
            phx-update="stream"
            phx-hook="ChatScroll"
            class="min-h-0 flex-1 overflow-y-auto py-2"
          >
            <p
              id="messages-empty"
              class="text-muted hidden px-4 py-8 text-center text-xs only:block"
            >
              No messages yet. Say hi!
            </p>
            <div
              :for={{dom_id, message} <- @streams.messages}
              id={dom_id}
              class="h-msg group/msg px-4 py-1.5"
            >
              <.message
                message={message}
                dom_id={dom_id}
                read_only={@read_only}
                user_id={@current_user["id"]}
              />
            </div>
          </div>

          <p id="typing-indicator" class="text-muted h-5 px-4 text-xs italic">
            {typing_text(@typing)}
          </p>

          <form
            :if={!@read_only}
            id="chat-form"
            phx-submit="send_message"
            phx-change="typing"
            phx-hook="ResetOnSubmit"
            class="flex gap-2 border-t border-[var(--line)] p-3"
          >
            <input
              id="chat-input"
              type="text"
              name="body"
              placeholder="Message everyone here"
              maxlength="1000"
              autocomplete="off"
              phx-throttle="1500"
              class="h-input min-w-0 flex-1"
            />
            <button type="submit" class="h-btn h-btn-primary w-9 px-0" aria-label="Send">
              <.icon name="hero-paper-airplane-micro" class="size-4" />
            </button>
          </form>
          <p
            :if={@read_only}
            id="chat-read-only"
            class="text-muted flex items-center justify-center gap-1.5 border-t border-[var(--line)] p-3 text-xs"
          >
            <.icon name="hero-lock-closed-micro" class="size-3.5" /> You're on a view-only link
          </p>
        </aside>
      </div>

      <.share_modal
        :if={@share_open}
        urls={share_urls(assigns)}
        kind={@share_kind}
        qr={@qr}
        read_only={@read_only}
        local={local_origin?(@origin)}
      />

      <canvas id="confetti" phx-hook="Confetti" phx-update="ignore" class="h-confetti"></canvas>
    </Layouts.app>
    """
  end

  ## Components

  attr :presenter, :map, default: nil
  attr :presenting, :boolean, required: true
  attr :following, :boolean, required: true

  defp presenter_banner(%{presenter: nil} = assigns), do: ~H""

  defp presenter_banner(%{presenting: true} = assigns) do
    ~H"""
    <div
      id="presenter-banner"
      class="h-banner flex items-center justify-center gap-3 bg-linear-to-r from-primary to-accent px-4 py-2 text-sm font-semibold text-primary-content"
    >
      <.icon name="hero-presentation-chart-bar-micro" class="size-4" />
      <span>You're presenting. Scroll, or click a card to spotlight it for everyone.</span>
      <button
        type="button"
        id="stop-presenting"
        phx-click="stop_presenting"
        class="h-btn h-btn-sm bg-black/20 hover:bg-black/30"
      >
        Stop
      </button>
    </div>
    """
  end

  defp presenter_banner(assigns) do
    ~H"""
    <div
      id="presenter-banner"
      class="h-banner flex items-center justify-center gap-3 border-b border-[var(--line)] bg-primary/15 px-4 py-2 text-sm"
    >
      <Layouts.avatar name={@presenter.name} color={@presenter.color} class="size-6 text-[10px]" />
      <span><strong class="font-semibold">{@presenter.name}</strong> is presenting</span>
      <button
        type="button"
        id="toggle-follow"
        phx-click="toggle_follow"
        aria-pressed={to_string(@following)}
        class={["h-btn h-btn-soft h-btn-sm", @following && "is-on"]}
      >
        <.icon :if={@following} name="hero-check-micro" class="size-3.5" />
        {if @following, do: "Following", else: "Follow"}
      </button>
    </div>
    """
  end

  attr :column, :map, required: true
  attr :editing, :boolean, required: true
  attr :read_only, :boolean, required: true
  attr :visible_count, :integer, required: true
  attr :filtering, :boolean, required: true

  defp column_header(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-4 pt-3 pb-2">
      <%= cond do %>
        <% @editing -> %>
          <form
            id={"rename-column-#{@column.id}"}
            phx-submit="rename_column"
            class="min-w-0 flex-1"
          >
            <input type="hidden" name="column_id" value={@column.id} />
            <input
              id={"rename-column-input-#{@column.id}"}
              type="text"
              name="title"
              value={@column.title}
              maxlength="40"
              autocomplete="off"
              required
              phx-mounted={JS.focus()}
              phx-blur="rename_column"
              phx-value-id={@column.id}
              phx-keydown="cancel_column_edit"
              phx-key="escape"
              class="h-input h-7 px-2 text-sm font-semibold"
            />
          </form>
        <% @read_only -> %>
          <h2 class="font-display min-w-0 flex-1 truncate text-sm font-bold">{@column.title}</h2>
        <% true -> %>
          <h2 class="min-w-0 flex-1">
            <button
              type="button"
              id={"edit-column-#{@column.id}"}
              phx-click="edit_column"
              phx-value-id={@column.id}
              title="Rename column"
              class="font-display -mx-1.5 max-w-full cursor-text truncate rounded-lg px-1.5 py-0.5 text-left text-sm font-bold transition hover:bg-[var(--soft)]"
            >
              {@column.title}
            </button>
          </h2>
      <% end %>

      <span
        id={"column-count-#{@column.id}-#{@visible_count}"}
        class="h-pop rounded-full bg-[var(--soft)] px-2 py-0.5 text-xs font-semibold tabular-nums"
      >
        {if @filtering,
          do: "#{@visible_count}/#{length(@column.cards)}",
          else: length(@column.cards)}
      </span>
      <button
        :if={!@read_only}
        type="button"
        id={"delete-column-#{@column.id}"}
        phx-click="delete_column"
        phx-value-id={@column.id}
        data-confirm="Delete this column and all of its cards?"
        aria-label="Delete column"
        class="h-icon-btn is-danger opacity-0 group-hover/col:opacity-100 focus:opacity-100"
      >
        <.icon name="hero-trash-micro" class="size-4" />
      </button>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :read_only, :boolean, required: true
  attr :votes_hidden, :boolean, required: true
  attr :user_id, :string, required: true

  defp card_body(assigns) do
    assigns =
      assigns
      |> assign(:label, label_for(assigns.card.label))
      |> assign(:reactions, Reactions.summarize(assigns.card.reactions, assigns.user_id))

    ~H"""
    <span :if={@label} class="h-label mb-1.5">
      <.icon name={@label.icon} class="size-3" />{@label.name}
    </span>
    <p class="text-sm leading-snug break-words">{@card.title}</p>

    <div :if={@reactions != []} class="mt-2 flex flex-wrap gap-1">
      <button
        :for={reaction <- @reactions}
        type="button"
        id={"card-#{@card.id}-reaction-#{reaction.index}"}
        phx-click="react_card"
        phx-value-id={@card.id}
        phx-value-emoji={reaction.emoji}
        disabled={@read_only}
        class={["h-chip", reaction.mine? && "is-on"]}
      >
        <span>{reaction.emoji}</span>
        <span
          id={"card-#{@card.id}-reaction-#{reaction.index}-count-#{reaction.count}"}
          class="h-pop tabular-nums"
        >
          {reaction.count}
        </span>
      </button>
    </div>

    <div class="text-muted mt-2 flex items-center gap-1 text-xs">
      <Layouts.avatar
        name={@card.author_name}
        color={@card.author_color}
        class="size-4 text-[7px]"
      />
      <span class="min-w-0 flex-1 truncate">{@card.author_name}</span>

      <div
        :if={!@read_only}
        class="flex items-center opacity-0 transition-opacity group-hover/card:opacity-100 focus-within:opacity-100"
      >
        <button
          type="button"
          id={"react-card-#{@card.id}"}
          phx-click={JS.toggle(to: "#card-#{@card.id}-picker", display: "flex")}
          aria-label="Add a reaction"
          class="h-icon-btn"
        >
          <.icon name="hero-face-smile-micro" class="size-3.5" />
        </button>
        <button
          type="button"
          id={"edit-card-button-#{@card.id}"}
          phx-click="edit_card"
          phx-value-id={@card.id}
          aria-label="Edit card"
          class="h-icon-btn"
        >
          <.icon name="hero-pencil-micro" class="size-3.5" />
        </button>
        <button
          type="button"
          id={"delete-card-#{@card.id}"}
          phx-click="delete_card"
          phx-value-id={@card.id}
          aria-label="Delete card"
          class="h-icon-btn is-danger"
        >
          <.icon name="hero-x-mark-micro" class="size-3.5" />
        </button>
      </div>

      <button
        type="button"
        id={"vote-card-#{@card.id}"}
        phx-click="vote_card"
        phx-value-id={@card.id}
        disabled={@read_only}
        aria-label="Vote for this card"
        title={if @votes_hidden, do: "Votes are hidden until someone reveals them"}
        class={[
          "h-chip",
          !@votes_hidden && @card.votes > 0 && "is-on"
        ]}
      >
        <.icon name="hero-hand-thumb-up-micro" class="size-3.5" />
        <span
          id={"votes-#{@card.id}-#{if @votes_hidden, do: "hidden", else: @card.votes}"}
          class="h-pop tabular-nums"
        >
          {if @votes_hidden, do: "?", else: @card.votes}
        </span>
      </button>
    </div>

    <div
      :if={!@read_only}
      id={"card-#{@card.id}-picker"}
      class="mt-2 hidden gap-0.5 rounded-full bg-[var(--soft)] p-1"
    >
      <button
        :for={{emoji, index} <- Enum.with_index(Reactions.emojis())}
        type="button"
        id={"card-#{@card.id}-pick-#{index}"}
        phx-click={
          JS.push("react_card", value: %{id: @card.id, emoji: emoji})
          |> JS.hide(to: "#card-#{@card.id}-picker")
        }
        class="grid size-7 flex-1 cursor-pointer place-items-center rounded-full text-base transition-transform duration-200 ease-[var(--ease-spring)] hover:scale-135"
      >
        {emoji}
      </button>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :form, :map, required: true

  defp card_editor(assigns) do
    ~H"""
    <.form
      for={@form}
      id={"edit-card-#{@card.id}"}
      phx-change="edit_change"
      phx-submit="save_card"
      class="space-y-2"
    >
      <.input
        field={@form[:title]}
        type="text"
        maxlength="140"
        autocomplete="off"
        class="h-input"
        error_class="h-input-error"
        phx-mounted={JS.focus()}
        phx-keydown="cancel_edit"
        phx-key="escape"
      />
      <div class="flex flex-wrap gap-1.5">
        <label class="h-chip">
          <input
            type="radio"
            name={@form[:label].name}
            value=""
            checked={@form[:label].value in [nil, ""]}
            class="sr-only"
          /> None
        </label>
        <label :for={label <- labels()} class="h-chip" style={"--tint: #{label.color}"}>
          <input
            type="radio"
            name={@form[:label].name}
            value={label.id}
            checked={@form[:label].value == label.id}
            class="sr-only"
          />
          <span class="h-chip-dot"></span>{label.name}
        </label>
      </div>
      <div class="flex justify-end gap-2">
        <button type="button" phx-click="cancel_edit" class="h-btn h-btn-ghost h-btn-sm">
          Cancel
        </button>
        <button type="submit" class="h-btn h-btn-primary h-btn-sm">Save</button>
      </div>
    </.form>
    """
  end

  attr :message, :map, required: true
  attr :dom_id, :string, required: true
  attr :read_only, :boolean, required: true
  attr :user_id, :string, required: true

  defp message(%{message: %{kind: "system"}} = assigns) do
    ~H"""
    <p class="text-muted mx-auto w-fit max-w-full rounded-full bg-[var(--soft)] px-3 py-1 text-center text-[11px]">
      {@message.body}
    </p>
    """
  end

  defp message(assigns) do
    assigns =
      assign(assigns, :reactions, Reactions.summarize(assigns.message.reactions, assigns.user_id))

    ~H"""
    <div class="flex items-start gap-2">
      <Layouts.avatar
        name={@message.author_name}
        color={@message.author_color}
        class="mt-0.5 size-6 text-[10px]"
      />
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-1">
          <p
            class="min-w-0 flex-1 truncate text-xs font-bold"
            style={"color: #{@message.author_color}"}
          >
            {@message.author_name}
          </p>
          <button
            :if={!@read_only}
            type="button"
            id={"#{@dom_id}-react"}
            phx-click={JS.toggle(to: "##{@dom_id}-picker", display: "flex")}
            aria-label="Add a reaction"
            class="h-icon-btn size-5 opacity-0 group-hover/msg:opacity-100 focus:opacity-100"
          >
            <.icon name="hero-face-smile-micro" class="size-3.5" />
          </button>
        </div>
        <p class="text-sm break-words whitespace-pre-wrap">{@message.body}</p>

        <div :if={@reactions != []} class="mt-1 flex flex-wrap gap-1">
          <button
            :for={reaction <- @reactions}
            type="button"
            id={"#{@dom_id}-reaction-#{reaction.index}"}
            phx-click="react_message"
            phx-value-id={@message.id}
            phx-value-emoji={reaction.emoji}
            disabled={@read_only}
            class={["h-chip", reaction.mine? && "is-on"]}
          >
            <span>{reaction.emoji}</span>
            <span
              id={"#{@dom_id}-reaction-#{reaction.index}-count-#{reaction.count}"}
              class="h-pop tabular-nums"
            >
              {reaction.count}
            </span>
          </button>
        </div>

        <div
          :if={!@read_only}
          id={"#{@dom_id}-picker"}
          class="mt-1 hidden w-fit gap-0.5 rounded-full bg-[var(--soft)] p-1"
        >
          <button
            :for={{emoji, index} <- Enum.with_index(Reactions.emojis())}
            type="button"
            id={"#{@dom_id}-pick-#{index}"}
            phx-click={
              JS.push("react_message", value: %{id: @message.id, emoji: emoji})
              |> JS.hide(to: "##{@dom_id}-picker")
            }
            class="grid size-7 cursor-pointer place-items-center rounded-full text-base transition-transform duration-200 ease-[var(--ease-spring)] hover:scale-135"
          >
            {emoji}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :urls, :map, required: true
  attr :kind, :string, required: true
  attr :qr, :map, required: true
  attr :read_only, :boolean, required: true
  attr :local, :boolean, required: true

  defp share_modal(assigns) do
    ~H"""
    <div id="share-modal" class="fixed inset-0 z-50 grid place-items-center p-4">
      <div
        id="share-backdrop"
        class="h-overlay absolute inset-0 bg-black/55 backdrop-blur-sm"
        phx-click="close_share"
      >
      </div>

      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="share-title"
        phx-window-keydown="close_share"
        phx-key="escape"
        class="h-panel relative w-full max-w-sm rounded-3xl border border-[var(--line)] bg-base-100 p-6 shadow-2xl"
      >
        <div class="flex items-start gap-3">
          <div class="min-w-0 flex-1">
            <h2 id="share-title" class="font-display text-xl font-bold">Invite people</h2>
            <p class="text-muted mt-0.5 text-sm">
              Anyone with the link can join. No sign-up needed.
            </p>
          </div>
          <button
            type="button"
            id="close-share"
            phx-click="close_share"
            aria-label="Close"
            class="h-icon-btn size-8"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>

        <div
          :if={!@read_only}
          id="share-kinds"
          class="mt-5 grid grid-cols-2 gap-1 rounded-2xl bg-[var(--soft)] p-1"
        >
          <button
            :for={
              {kind, icon, text} <- [
                {"edit", "hero-pencil-micro", "Can edit"},
                {"view", "hero-eye-micro", "View only"}
              ]
            }
            type="button"
            id={"share-kind-#{kind}"}
            phx-click="share_kind"
            phx-value-kind={kind}
            aria-pressed={to_string(@kind == kind)}
            class={[
              "flex h-9 cursor-pointer items-center justify-center gap-1.5 rounded-xl text-sm font-semibold transition",
              if(@kind == kind,
                do: "bg-base-100 shadow-sm",
                else: "text-muted hover:text-base-content"
              )
            ]}
          >
            <.icon name={icon} class="size-4" />{text}
          </button>
        </div>

        <div
          :if={@qr[@kind]}
          id={"share-qr-#{@kind}"}
          class="h-pop mx-auto mt-5 size-44 overflow-hidden rounded-2xl bg-white p-1 shadow-lg ring-1 ring-black/5"
        >
          {raw(@qr[@kind])}
        </div>
        <p class="text-muted mt-3 text-center text-xs">
          {if @kind == "view",
            do: "People with this link can watch, but not change anything.",
            else: "People with this link can add, move and edit cards."}
        </p>

        <div class="mt-4 flex gap-2">
          <input
            id="share-url"
            type="text"
            readonly
            value={@urls[@kind]}
            aria-label="Link to this board"
            class="h-input min-w-0 flex-1 font-mono text-xs"
          />
          <button
            type="button"
            id={"copy-link-#{@kind}"}
            phx-hook="Copy"
            phx-update="ignore"
            data-copy={@urls[@kind]}
            class="h-btn h-btn-primary group/copy shrink-0"
          >
            <span class="inline-flex items-center gap-1.5 group-[.is-copied]/copy:hidden">
              <.icon name="hero-link-micro" class="size-4" /> Copy
            </span>
            <span class="hidden items-center gap-1.5 group-[.is-copied]/copy:inline-flex">
              <.icon name="hero-check-micro" class="size-4" /> Copied!
            </span>
          </button>
        </div>

        <p
          :if={@local}
          id="share-local-hint"
          class="mt-4 flex items-start gap-2 rounded-2xl bg-warning/15 p-3 text-xs"
        >
          <.icon name="hero-information-circle-micro" class="mt-0.5 size-4 shrink-0 text-warning" />
          <span>
            This link starts with <strong>localhost</strong>, so it only opens on this computer.
            To invite other people, put the app online or open it through your network address.
          </span>
        </p>
      </div>
    </div>
    """
  end
end
