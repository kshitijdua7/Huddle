defmodule Huddle.Chat.Message do
  @moduledoc """
  A chat message on a board. `kind` is `"user"` for messages people type and
  `"system"` for activity notes such as "Ada moved a card".
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :body, :string
    field :kind, :string, default: "user"
    field :author_name, :string
    field :author_color, :string
    # %{"👍" => [user_id, ...]}, see `Huddle.Reactions`
    field :reactions, :map, default: %{}

    belongs_to :board, Huddle.Boards.Board

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, max: 1000)
  end
end
