defmodule Huddle.Boards.Card do
  @moduledoc """
  A card on a board. `board_id`, `column_id`, `position` and the author fields
  are set by the `Huddle.Boards` context, never cast from user input.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @labels ~w(idea bug urgent question win)

  @doc "The labels a card can carry."
  def labels, do: @labels

  schema "cards" do
    field :title, :string
    field :label, :string
    # %{"👍" => [user_id, ...]}, see `Huddle.Reactions`
    field :reactions, :map, default: %{}
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
    |> cast(attrs, [:title, :label])
    |> update_change(:title, &(&1 && String.trim(&1)))
    |> validate_required([:title])
    |> validate_length(:title, max: 140)
    |> validate_inclusion(:label, @labels)
  end
end
