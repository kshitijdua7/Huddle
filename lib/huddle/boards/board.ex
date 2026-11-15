defmodule Huddle.Boards.Board do
  @moduledoc """
  A shared board. Anyone with the link (the `slug`) can collaborate on it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :slug, :string
    # The slug of the read-only link. Whoever has it can watch but not edit.
    field :view_slug, :string
    # While true, vote counts are hidden from everyone ("anonymous voting").
    field :votes_hidden, :boolean, default: false

    has_many :columns, Huddle.Boards.Column, preload_order: [asc: :position, asc: :id]
    has_many :cards, Huddle.Boards.Card

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> unique_constraint(:slug)
    |> unique_constraint(:view_slug)
  end
end
