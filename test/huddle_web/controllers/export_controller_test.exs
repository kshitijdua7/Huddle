defmodule HuddleWeb.ExportControllerTest do
  use HuddleWeb.ConnCase

  import Huddle.Fixtures

  setup do
    board = board_fixture(%{"name" => "Sprint: Planning!"})
    card_fixture(hd(board.columns), "Ship it")
    %{board: board}
  end

  test "downloads the board as Markdown", %{conn: conn, board: board} do
    conn = get(conn, ~p"/b/#{board.slug}/export/md")

    assert response_content_type(conn, :markdown) =~ "charset=utf-8"

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="sprint-planning.md")
           ]

    assert response(conn, 200) =~ "- Ship it"
  end

  test "downloads the board as CSV through the view-only link", %{conn: conn, board: board} do
    conn = get(conn, ~p"/v/#{board.view_slug}/export/csv")

    assert response_content_type(conn, :csv) =~ "charset=utf-8"
    assert response(conn, 200) =~ ~s("To do","1","Ship it")
  end

  test "the edit slug does not work on the view-only route", %{conn: conn, board: board} do
    conn = get(conn, ~p"/v/#{board.slug}/export/md")
    assert redirected_to(conn) == ~p"/"
  end

  test "redirects home for an unknown board or format", %{conn: conn, board: board} do
    assert conn |> get(~p"/b/missing/export/md") |> redirected_to() == ~p"/"
    assert conn |> get(~p"/b/#{board.slug}/export/pdf") |> redirected_to() == ~p"/"
  end
end
