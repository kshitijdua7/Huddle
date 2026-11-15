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

  test "renders the board, its columns and existing cards", %{conn: conn, board: board, todo: todo} do
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
    render_hook(view, "move_card", %{"id" => "#{card.id}", "column_id" => "#{done.id}", "index" => 0})

    assert has_element?(view, "#cards-#{done.id} #card-#{card.id}")
    refute has_element?(view, "#cards-#{todo.id} #card-#{card.id}")
    assert has_element?(view, "#messages", "to Done")
  end

  test "ignores a move to a column of another board", %{conn: conn, board: board, todo: todo} do
    other = board_fixture(%{"name" => "Other"})
    [foreign | _] = other.columns
    card = card_fixture(todo)
    {:ok, view, _html} = live(conn, ~p"/b/#{board.slug}")

    render_hook(view, "move_card", %{"id" => "#{card.id}", "column_id" => "#{foreign.id}", "index" => 0})

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
    {:ok, _message} = Chat.create_message(board, user_fixture(%{"name" => "Grace"}), %{"body" => "earlier"})
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
end
