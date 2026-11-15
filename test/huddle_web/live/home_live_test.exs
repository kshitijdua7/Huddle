defmodule HuddleWeb.HomeLiveTest do
  use HuddleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Huddle.Fixtures

  alias Huddle.Boards

  test "shows the create form and an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#new-board-form")
    assert has_element?(view, "#boards-empty")
    assert has_element?(view, "#user-menu")
  end

  test "lists the boards this visitor has opened, and no one else's", %{conn: conn} do
    user = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user: user})

    mine = board_fixture(%{"name" => "Roadmap"})
    watched = board_fixture(%{"name" => "Retro"})
    theirs = board_fixture(%{"name" => "Someone else's"})
    Boards.record_visit(mine, user["id"], false)
    Boards.record_visit(watched, user["id"], true)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#board-#{mine.id} a[href='/b/#{mine.slug}']", "Roadmap")

    assert has_element?(
             view,
             "#board-#{watched.id} a[href='/v/#{watched.view_slug}']",
             "view only"
           )

    refute has_element?(view, "#board-#{theirs.id}")
    refute has_element?(view, "#boards-empty")
  end

  test "validates the board name while typing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("#new-board-form", board: %{name: "x"}) |> render_change()
    assert html =~ "should be at least 2 character(s)"
  end

  test "creating a board opens it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    {:ok, board_view, _html} =
      view
      |> form("#new-board-form", board: %{name: "Sprint 12"})
      |> render_submit()
      |> follow_redirect(conn)

    assert has_element?(board_view, "#board-name", "Sprint 12")
  end
end
