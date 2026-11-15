defmodule HuddleWeb.BoardLiveTest do
  use HuddleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Huddle.Fixtures

  alias Huddle.{Boards, BoardServer, Chat}

  setup do
    board = board_fixture()
    [todo, doing, done] = board.columns
    %{board: board, todo: todo, doing: doing, done: done}
  end

  test "redirects home when the board does not exist", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/b/nope")
  end

  test "renders the board, its columns and existing cards", %{
    conn: conn,
    board: board,
    todo: todo
  } do
    card = card_fixture(todo, "Ship it")
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    assert has_element?(view, "#board-name", "Sprint planning")
    for column <- board.columns, do: assert(has_element?(view, "#column-#{column.id}"))
    assert has_element?(view, "#cards-#{todo.id} #card-#{card.id}", "Ship it")
    assert has_element?(view, "#card-count", "1")
  end

  test "shows the visitor in the presence list", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    assert has_element?(view, "#presence-list [data-user-id]")
    assert has_element?(view, "#online-count", "1 online")
  end

  test "adding a card shows it in the column", %{conn: conn, board: board, todo: todo} do
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    view |> form("#add-card-#{todo.id}", %{title: "Write the README"}) |> render_submit()

    assert has_element?(view, "#cards-#{todo.id} [data-card-id]", "Write the README")
  end

  test "changes made in one browser appear in another", %{conn: conn, board: board, todo: todo} do
    {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
    {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

    first |> form("#add-card-#{todo.id}", %{title: "Synced card"}) |> render_submit()
    assert has_element?(second, "#cards-#{todo.id} [data-card-id]", "Synced card")

    first |> form("#chat-form", %{body: "hello from the first tab"}) |> render_submit()
    assert has_element?(second, "#messages", "hello from the first tab")

    assert has_element?(second, "#online-count", "2 online")
  end

  test "voting for and deleting a card", %{conn: conn, board: board, todo: todo} do
    card = card_fixture(todo)
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    view |> element("#vote-card-#{card.id}") |> render_click()
    assert has_element?(view, "#vote-card-#{card.id}", "1")

    view |> element("#delete-card-#{card.id}") |> render_click()
    refute has_element?(view, "#card-#{card.id}")
  end

  test "moving a card to another column notes it in the chat",
       %{conn: conn, board: board, todo: todo, done: done} do
    card = card_fixture(todo, "Finish me")
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    # This is the event the drag-and-drop hook pushes when a card is dropped.
    render_hook(view, "move_card", %{
      "id" => "#{card.id}",
      "column_id" => "#{done.id}",
      "index" => 0
    })

    assert has_element?(view, "#cards-#{done.id} #card-#{card.id}")
    refute has_element?(view, "#cards-#{todo.id} #card-#{card.id}")
    assert has_element?(view, "#messages", "to Done")
  end

  test "ignores a move to a column of another board", %{conn: conn, board: board, todo: todo} do
    other = board_fixture(%{"name" => "Other"})
    [foreign | _] = other.columns
    card = card_fixture(todo)
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    render_hook(view, "move_card", %{
      "id" => "#{card.id}",
      "column_id" => "#{foreign.id}",
      "index" => 0
    })

    assert has_element?(view, "#cards-#{todo.id} #card-#{card.id}")
  end

  test "adding and deleting a column", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    view |> form("#add-column-form", %{title: "Blocked"}) |> render_submit()
    column = board.slug |> Boards.get_board_by_slug() |> Map.fetch!(:columns) |> List.last()
    assert has_element?(view, "#column-#{column.id}", "Blocked")

    view |> element("#delete-column-#{column.id}") |> render_click()
    refute has_element?(view, "#column-#{column.id}")
  end

  test "shows earlier chat messages and new ones", %{conn: conn, board: board} do
    {:ok, _message} =
      Chat.create_message(board, user_fixture(%{"name" => "Grace"}), %{"body" => "earlier"})

    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    assert has_element?(view, "#messages", "earlier")

    view |> form("#chat-form", %{body: "hi there"}) |> render_submit()
    assert has_element?(view, "#messages", "hi there")
  end

  test "shows who is typing in other browsers only", %{conn: conn, board: board} do
    {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
    {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

    first |> form("#chat-form", %{body: "hel"}) |> render_change()

    assert has_element?(second, "#typing-indicator", "is typing")
    refute has_element?(first, "#typing-indicator", "is typing")
  end

  test "the shared timer starts and stops for everyone", %{conn: conn, board: board} do
    {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
    {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

    first |> element("#start-timer-5") |> render_click()

    assert has_element?(first, "#timer[data-ends-at]")
    assert has_element?(second, "#timer[data-ends-at]")
    assert %DateTime{} = BoardServer.timer(board.id)

    second |> element("#stop-timer") |> render_click()

    refute has_element?(first, "#timer[data-ends-at]")
    assert BoardServer.timer(board.id) == nil
  end

  test "relays cursor positions to other browsers", %{conn: conn, board: board} do
    {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
    {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

    render_hook(first, "cursor", %{"x" => 0.25, "y" => 2})

    assert_push_event(second, "cursor", %{x: 0.25, y: 1})
  end

  describe "editing" do
    test "a card's title and label can be changed", %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo, "Old title")
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

      view |> element("#edit-card-button-#{card.id}") |> render_click()
      assert has_element?(view, "#edit-card-#{card.id}")

      view
      |> form("#edit-card-#{card.id}", card: %{title: "New title", label: "bug"})
      |> render_submit()

      refute has_element?(view, "#edit-card-#{card.id}")
      assert has_element?(view, "#card-#{card.id}[data-label='bug']", "New title")
    end

    test "a blank title keeps the editor open", %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo, "Keep me")
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

      # This is the event the board hook pushes on a double-click.
      render_hook(view, "edit_card", %{"id" => "#{card.id}"})
      view |> form("#edit-card-#{card.id}", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#edit-card-#{card.id}")
      assert card_titles(board, todo.id) == ["Keep me"]
    end

    test "a column can be renamed", %{conn: conn, board: board, todo: todo} do
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

      view |> element("#edit-column-#{todo.id}") |> render_click()
      view |> form("#rename-column-#{todo.id}", %{title: "Backlog"}) |> render_submit()

      assert has_element?(view, "#edit-column-#{todo.id}", "Backlog")
      refute has_element?(view, "#rename-column-#{todo.id}")
    end
  end

  describe "reactions" do
    test "reacting to a card toggles and syncs", %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo)
      {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
      {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

      first |> element("#card-#{card.id}-pick-0") |> render_click()
      assert has_element?(first, "#card-#{card.id}-reaction-0.is-on", "1")
      assert has_element?(second, "#card-#{card.id}-reaction-0:not(.is-on)", "1")

      second |> element("#card-#{card.id}-reaction-0") |> render_click()
      assert has_element?(first, "#card-#{card.id}-reaction-0", "2")

      first |> element("#card-#{card.id}-reaction-0") |> render_click()
      second |> element("#card-#{card.id}-reaction-0") |> render_click()
      refute has_element?(first, "#card-#{card.id}-reaction-0")
    end

    test "reacting to a chat message", %{conn: conn, board: board} do
      {:ok, message} = Chat.create_message(board, user_fixture(), %{"body" => "nice"})
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

      view |> element("#messages-#{message.id}-pick-2") |> render_click()

      assert has_element?(view, "#messages-#{message.id}-reaction-2.is-on", "1")
    end
  end

  describe "search and filters" do
    test "hide the cards that do not match", %{conn: conn, board: board, todo: todo} do
      login = card_fixture(todo, "Fix the login page")
      docs = card_fixture(todo, "Write the docs")
      {:ok, _card} = Boards.update_card(docs, %{"label" => "idea"})
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

      view |> form("#search-form", %{q: "LOGIN"}) |> render_change()
      assert has_element?(view, "#card-#{login.id}:not(.hidden)")
      assert has_element?(view, "#card-#{docs.id}.hidden")

      view |> element("#clear-filters") |> render_click()
      view |> element("#filter-idea") |> render_click()
      assert has_element?(view, "#card-#{login.id}.hidden")
      assert has_element?(view, "#card-#{docs.id}:not(.hidden)")

      view |> element("#filter-idea") |> render_click()
      refute has_element?(view, "[data-card-id].hidden")
    end
  end

  describe "anonymous voting" do
    test "hides the counts for everyone until they are revealed",
         %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo)
      {:ok, first, _html} = live(conn, ~p"/b/#{board.slug}")
      {:ok, second, _html} = live(build_conn(), ~p"/b/#{board.slug}")

      first |> element("#toggle-votes") |> render_click()
      second |> element("#vote-card-#{card.id}") |> render_click()

      assert has_element?(first, "#votes-#{card.id}-hidden", "?")
      assert has_element?(second, "#votes-#{card.id}-hidden", "?")

      second |> element("#toggle-votes") |> render_click()
      assert has_element?(first, "#vote-card-#{card.id}", "1")
    end
  end

  describe "sharing" do
    test "shows the edit and view-only links with QR codes", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")
      refute has_element?(view, "#share-modal")

      view |> element("#share-button") |> render_click()
      assert has_element?(view, "#share-url[value$='/b/#{board.slug}']")
      assert has_element?(view, "#copy-link-edit[data-copy$='/b/#{board.slug}']")
      assert has_element?(view, "#share-qr-edit svg")

      view |> element("#share-kind-view") |> render_click()
      assert has_element?(view, "#share-url[value$='/v/#{board.view_slug}']")
      assert has_element?(view, "#share-qr-view svg")

      view |> element("#close-share") |> render_click()
      refute has_element?(view, "#share-modal")
    end
  end

  describe "the view-only link" do
    test "redirects home when it does not exist", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/v/nope")
    end

    test "shows the board without any way to change it",
         %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo, "Look, don't touch")
      {:ok, view, html} = live(conn, ~p"/v/#{board.view_slug}")

      assert has_element?(view, "#read-only-badge")
      assert has_element?(view, "#card-#{card.id}", "Look, don't touch")
      refute has_element?(view, "#add-card-#{todo.id}")
      refute has_element?(view, "#add-column-form")
      refute has_element?(view, "#delete-card-#{card.id}")
      refute has_element?(view, "#chat-form")
      refute has_element?(view, "#toggle-votes")
      refute has_element?(view, "#card-#{card.id}[draggable]")

      # The edit link must never reach someone who only has the view link.
      refute html =~ board.slug
      view |> element("#share-button") |> render_click()
      refute render(view) =~ board.slug
      assert has_element?(view, "#share-url[value$='/v/#{board.view_slug}']")
      refute has_element?(view, "#share-kinds")
    end

    test "ignores hand-crafted events that would change the board",
         %{conn: conn, board: board, todo: todo, done: done} do
      card = card_fixture(todo, "Still here")
      {:ok, view, _html} = live(conn, ~p"/v/#{board.view_slug}")

      render_hook(view, "delete_card", %{"id" => "#{card.id}"})
      render_hook(view, "vote_card", %{"id" => "#{card.id}"})
      render_hook(view, "add_card", %{"column_id" => "#{todo.id}", "title" => "Sneaky"})
      render_hook(view, "move_card", %{"id" => "#{card.id}", "column_id" => "#{done.id}"})
      render_hook(view, "send_message", %{"body" => "sneaky"})
      render_hook(view, "toggle_votes", %{})
      render_hook(view, "start_presenting", %{})

      assert card_titles(board, todo.id) == ["Still here"]
      assert Boards.get_card(board, card.id).votes == 0
      assert Chat.list_messages(board) == []
      refute Boards.get_board_by_slug(board.slug).votes_hidden
      assert BoardServer.presenter(board.id) == nil
    end

    test "still follows changes made by editors", %{conn: conn, board: board, todo: todo} do
      {:ok, viewer, _html} = live(conn, ~p"/v/#{board.view_slug}")
      {:ok, editor, _html} = live(build_conn(), ~p"/b/#{board.slug}")

      editor |> form("#add-card-#{todo.id}", %{title: "From the editor"}) |> render_submit()

      assert has_element?(viewer, "#cards-#{todo.id} [data-card-id]", "From the editor")
      assert has_element?(viewer, "#online-count", "2 online")
    end
  end

  describe "presenting" do
    test "others follow the presenter's scrolling and spotlight until they opt out",
         %{conn: conn, board: board, todo: todo} do
      card = card_fixture(todo)
      card_id = card.id
      {:ok, presenter, _html} = live(conn, ~p"/b/#{board.slug}")
      {:ok, follower, _html} = live(build_conn(), ~p"/b/#{board.slug}")

      presenter |> element("#present-toggle") |> render_click()
      assert has_element?(presenter, "#columns[data-presenting='true']")
      assert has_element?(follower, "#presenter-banner", "is presenting")
      assert has_element?(follower, "#columns[data-presenting='false']")

      render_hook(presenter, "present_scroll", %{"x" => 0.5})
      assert_push_event(follower, "follow_scroll", %{x: 0.5})

      render_hook(presenter, "spotlight", %{"id" => "#{card.id}"})
      assert_push_event(follower, "spotlight", %{id: ^card_id})
      assert has_element?(follower, "#card-#{card.id}.is-spotlight")

      # Only the presenter's scrolling counts.
      render_hook(follower, "present_scroll", %{"x" => 0.9})
      refute_push_event(presenter, "follow_scroll", %{})

      follower |> element("#toggle-follow") |> render_click()
      render_hook(presenter, "present_scroll", %{"x" => 0.7})
      refute_push_event(follower, "follow_scroll", %{x: 0.7})

      presenter |> element("#stop-presenting") |> render_click()
      refute has_element?(follower, "#presenter-banner")
      refute has_element?(follower, "#card-#{card.id}.is-spotlight")
    end

    test "ends when the presenter leaves", %{conn: conn, board: board} do
      {:ok, presenter, _html} = live(conn, ~p"/b/#{board.slug}")
      {:ok, follower, _html} = live(build_conn(), ~p"/b/#{board.slug}")

      presenter |> element("#present-toggle") |> render_click()
      assert has_element?(follower, "#presenter-banner")

      Boards.subscribe(board)
      GenServer.stop(presenter.pid)
      assert_receive {:presenter_changed, nil}

      refute has_element?(follower, "#presenter-banner")
    end
  end

  test "the timer finishing sets off the confetti", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    send(view.pid, :timer_finished)

    assert_push_event(view, "confetti", %{})
  end
end
