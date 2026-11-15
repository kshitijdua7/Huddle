defmodule Huddle.Boards.Card do
  @moduledoc """
  A card on a board. `board_id`, `column_id`, `position` and the author fields
  are set by the `Huddle.Boards` context, never cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :position, :integer, default: 0
    field :votes, :integer, default: 0
    field :author_name, :string
    field :author_color, :string

    belongs_to :board, Huddle.Boards.Board
    belongs_to :column, Huddle.Boards.Column

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 140)
  end
end
