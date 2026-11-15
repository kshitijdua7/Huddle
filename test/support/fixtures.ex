defmodule Huddle.Fixtures do
  @moduledoc """
  Helpers for building test data through the public context functions.
  """

  alias Huddle.Boards

  def user_fixture(attrs \\ %{}) do
    Map.merge(%{"id" => Ecto.UUID.generate(), "name" => "Ada", "color" => "#6366f1"}, attrs)
  end

  @doc "Creates a board and returns it with its three default columns preloaded."
  def board_fixture(attrs \\ %{}) do
    {:ok, board} = Boards.create_board(Map.merge(%{"name" => "Sprint planning"}, attrs))
    Boards.get_board_by_slug(board.slug)
  end

  def card_fixture(column, title \\ "Write tests", user \\ user_fixture()) do
    {:ok, card} = Boards.create_card(column, user, %{"title" => title})
    card
  end

  @doc "The card titles of a column, in display order."
  def card_titles(board, column_id) do
    board = Boards.get_board_by_slug(board.slug)
    column = Enum.find(board.columns, &(&1.id == column_id))
    Enum.map(column.cards, & &1.title)
  end
end
