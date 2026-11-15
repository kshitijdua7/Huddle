defmodule Huddle.BoardsTest do
  use Huddle.DataCase, async: true

  import Huddle.Fixtures

  alias Huddle.Boards
  alias Huddle.Boards.Board

  describe "boards" do
    test "create_board/1 creates the board with a slug and the default columns" do
      assert {:ok, %Board{} = board} = Boards.create_board(%{"name" => "  Roadmap  "})
      assert board.name == "Roadmap"
      assert is_binary(board.slug) and board.slug != ""

      board = Boards.get_board_by_slug(board.slug)
      assert Enum.map(board.columns, & &1.title) == ["To do", "In progress", "Done"]
      assert Enum.map(board.columns, & &1.position) == [0, 1, 2]
    end

    test "create_board/1 rejects a blank or too short name" do
      assert {:error, changeset} = Boards.create_board(%{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} = Boards.create_board(%{"name" => "x"})
      assert "should be at least 2 character(s)" in errors_on(changeset).name
    end

    test "create_board/1 announces the new board" do
      Boards.subscribe_boards()
      {:ok, board} = Boards.create_board(%{"name" => "Announced"})
      board_id = board.id
      assert_receive {:board_created, %Board{id: ^board_id}}
    end

    test "get_board_by_slug/1 returns nil for an unknown slug" do
      assert Boards.get_board_by_slug("missing") == nil
    end

    test "list_recent_boards/1 returns newest first with card counts" do
      older = board_fixture(%{"name" => "Older"})
      newer = board_fixture(%{"name" => "Newer"})
      card_fixture(hd(older.columns))
      card_fixture(hd(older.columns), "Another")

      assert [%{board: first, card_count: 0}, %{board: second, card_count: 2}] =
               Boards.list_recent_boards()

      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "columns" do
    test "create_column/2 appends a column" do
      board = board_fixture()
      assert {:ok, column} = Boards.create_column(board, %{"title" => "Blocked"})
      assert column.position == 3
    end

    test "delete_column/1 removes the column and its cards" do
      board = board_fixture()
      [todo | _] = board.columns
      card = card_fixture(todo)

      assert {:ok, _column} = Boards.delete_column(todo)
      assert Boards.get_column(board, todo.id) == nil
      assert Boards.get_card(board, card.id) == nil
    end

    test "get_column/2 only finds columns of the given board" do
      board = board_fixture()
      other = board_fixture(%{"name" => "Other"})
      [foreign | _] = other.columns

      assert Boards.get_column(board, foreign.id) == nil
      assert Boards.get_column(board, "not-a-number") == nil
    end
  end

  describe "cards" do
    setup do
      board = board_fixture()
      [todo, doing, done] = board.columns
      %{board: board, todo: todo, doing: doing, done: done}
    end

    test "create_card/3 appends to the column and records the author", %{todo: todo} do
      user = user_fixture(%{"name" => "Grace", "color" => "#ec4899"})

      assert {:ok, first} = Boards.create_card(todo, user, %{"title" => " First "})
      assert {:ok, second} = Boards.create_card(todo, user, %{"title" => "Second"})

      assert first.title == "First"
      assert first.author_name == "Grace"
      assert first.author_color == "#ec4899"
      assert {first.position, second.position} == {0, 1}
    end

    test "create_card/3 rejects a blank title", %{todo: todo} do
      assert {:error, changeset} = Boards.create_card(todo, user_fixture(), %{"title" => "  "})
      assert "can't be blank" in errors_on(changeset).title
    end

    test "writes are broadcast to the board's subscribers", %{board: board, todo: todo} do
      Boards.subscribe(board)
      board_id = board.id

      card = card_fixture(todo)
      assert_receive {:board_changed, ^board_id}

      {:ok, _card} = Boards.vote_card(card)
      assert_receive {:board_changed, ^board_id}
    end

    test "vote_card/1 increments the votes", %{board: board, todo: todo} do
      card = card_fixture(todo)

      assert {:ok, %{votes: 1}} = Boards.vote_card(card)
      assert {:ok, _card} = Boards.vote_card(card)
      assert Boards.get_card(board, card.id).votes == 2
    end

    test "delete_card/1 removes the card", %{board: board, todo: todo} do
      card = card_fixture(todo)
      assert {:ok, _card} = Boards.delete_card(card)
      assert Boards.get_card(board, card.id) == nil
    end

    test "move_card/3 reorders within a column", %{board: board, todo: todo} do
      a = card_fixture(todo, "A")
      _b = card_fixture(todo, "B")
      _c = card_fixture(todo, "C")

      assert {:ok, _card} = Boards.move_card(a, todo.id, 2)
      assert card_titles(board, todo.id) == ["B", "C", "A"]
    end

    test "move_card/3 moves between columns and renumbers both",
         %{board: board, todo: todo, doing: doing} do
      a = card_fixture(todo, "A")
      _b = card_fixture(todo, "B")
      _x = card_fixture(doing, "X")
      _y = card_fixture(doing, "Y")

      assert {:ok, moved} = Boards.move_card(a, doing.id, 1)
      assert moved.column_id == doing.id

      assert card_titles(board, todo.id) == ["B"]
      assert card_titles(board, doing.id) == ["X", "A", "Y"]

      board = Boards.get_board_by_slug(board.slug)
      for column <- board.columns do
        assert Enum.map(column.cards, & &1.position) == Enum.to_list(0..(length(column.cards) - 1)//1)
      end
    end

    test "move_card/3 clamps an out-of-range index", %{board: board, todo: todo, done: done} do
      a = card_fixture(todo, "A")
      _z = card_fixture(done, "Z")

      assert {:ok, _card} = Boards.move_card(a, done.id, 99)
      assert card_titles(board, done.id) == ["Z", "A"]
    end

    test "move_card/3 refuses a column from another board", %{board: board, todo: todo} do
      other = board_fixture(%{"name" => "Other"})
      [foreign | _] = other.columns
      card = card_fixture(todo)

      assert Boards.move_card(card, foreign.id, 0) == {:error, :not_found}
      assert Boards.get_card(board, card.id).column_id == todo.id
    end
  end
end
