defmodule HuddleWeb.HomeLiveTest do
  use HuddleWeb.ConnCase

  import Phoenix.LiveViewTest
  import Huddle.Fixtures

  test "shows the create form and an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#new-board-form")
    assert has_element?(view, "#boards-empty")
    assert has_element?(view, "#user-menu")
  end

  test "lists recent boards", %{conn: conn} do
    board = board_fixture(%{"name" => "Roadmap"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#board-#{board.id}", "Roadmap")
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

  test "a board created elsewhere appears without a reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    board = board_fixture(%{"name" => "Made in another tab"})

    assert has_element?(view, "#board-#{board.id}", "Made in another tab")
  end
end
