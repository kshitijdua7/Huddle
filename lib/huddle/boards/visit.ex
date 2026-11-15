defmodule Huddle.Boards.Visit do
  @moduledoc """
  Remembers that a visitor (a guest identity id) opened a board, so the home
  page can list "your boards". `read_only` is true while the visitor has only
  ever used the board's read-only link.
  """
  use Ecto.Schema

  schema "board_visits" do
    field :user_id, :string
    field :read_only, :boolean, default: false

    belongs_to :board, Huddle.Boards.Board

    timestamps(type: :utc_datetime)
  end
end
