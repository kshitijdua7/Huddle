defmodule Huddle.Boards.ExportTest do
  use Huddle.DataCase, async: true

  import Huddle.Fixtures

  alias Huddle.Boards
  alias Huddle.Boards.Export

  setup do
    board = board_fixture(%{"name" => "Retro"})
    [todo, _doing, _done] = board.columns
    ada = user_fixture(%{"name" => "Ada"})

    card = card_fixture(todo, ~s(Say "hi", then go), ada)
    {:ok, card} = Boards.update_card(card, %{"label" => "idea"})
    {:ok, card} = Boards.vote_card(card)
    {:ok, _card} = Boards.toggle_card_reaction(card, "ada", "🎉")
    card_fixture(todo, "=SUM(A1:A9)", ada)

    %{board: Boards.get_board_by_slug(board.slug)}
  end

  test "to_markdown/1 lists every column and card", %{board: board} do
    markdown = Export.to_markdown(board)

    assert markdown =~ "# Retro\n"
    assert markdown =~ "## To do (2)\n"
    assert markdown =~ ~s(- **[idea]** Say "hi", then go — Ada · 1 vote · 🎉 1\n)
    assert markdown =~ "## Done (0)\n\n_No cards_\n"
  end

  test "to_csv/1 quotes fields and defuses spreadsheet formulas", %{board: board} do
    [header, first, second | _] = board |> Export.to_csv() |> String.split("\r\n")

    assert header ==
             ~S|"column","position","title","label","author","votes","reactions","created_at"|

    assert first =~ ~S|"To do","1","Say ""hi"", then go","idea","Ada","1","🎉 1",|
    assert second =~ ~S|"To do","2","'=SUM(A1:A9)","","Ada","0","",|
  end

  test "votes are left out while they are hidden", %{board: board} do
    {:ok, _board} = Boards.set_votes_hidden(board, true)
    board = Boards.get_board_by_slug(board.slug)

    refute Export.to_markdown(board) =~ "vote"
    assert Export.to_csv(board) =~ ~S|"idea","Ada","","🎉 1"|
  end
end
