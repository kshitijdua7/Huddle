defmodule Huddle.Boards.Column do
  @moduledoc """
  A column (list) on a board. Columns and their cards are ordered by `position`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "columns" do
    field :title, :string
    field :position, :integer, default: 0

    belongs_to :board, Huddle.Boards.Board
    has_many :cards, Huddle.Boards.Card, preload_order: [asc: :position, asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(column, attrs) do
    column
    |> cast(attrs, [:title])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:title])
    |> validate_length(:title, max: 40)
  end
end
