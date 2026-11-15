defmodule Huddle.Boards do
  @moduledoc """
  The Boards context: boards, columns and cards.

  Every successful write broadcasts `{:board_changed, board_id}` on the board's
  PubSub topic. Each connected LiveView reloads the board when it receives that
  message, which is what keeps every browser in sync.
  """

  import Ecto.Query, warn: false

  alias Huddle.Boards.{Board, Card, Column, Visit}
  alias Huddle.{Reactions, Repo}

  @default_columns ["To do", "In progress", "Done"]
  @boards_topic "boards"

  ## PubSub

  @doc "The PubSub topic for a single board."
  def topic(board_id), do: "board:#{board_id}"

  @doc "Subscribes the caller to changes on one board."
  def subscribe(%Board{id: board_id}) do
    Phoenix.PubSub.subscribe(Huddle.PubSub, topic(board_id))
  end

  @doc "Subscribes the caller to `{:board_created, board}` messages."
  def subscribe_boards do
    Phoenix.PubSub.subscribe(Huddle.PubSub, @boards_topic)
  end

  defp broadcast_change(board_id) do
    Phoenix.PubSub.broadcast(Huddle.PubSub, topic(board_id), {:board_changed, board_id})
  end

  defp notify({:ok, result}, board_id) do
    broadcast_change(board_id)
    {:ok, result}
  end

  defp notify(error, _board_id), do: error

  ## Boards

  @doc """
  Lists the most recently created boards along with how many cards each has.

  Returns a list of `%{board: %Board{}, card_count: integer}` maps.
  """
  def list_recent_boards(limit \\ 12) do
    from(b in Board,
      left_join: c in assoc(b, :cards),
      group_by: b.id,
      order_by: [desc: b.inserted_at, desc: b.id],
      limit: ^limit,
      select: %{board: b, card_count: count(c.id)}
    )
    |> Repo.all()
  end

  @doc "Fetches a board by its slug with columns and cards preloaded in order, or `nil`."
  def get_board_by_slug(slug) when is_binary(slug) do
    case Repo.get_by(Board, slug: slug) do
      nil -> nil
      board -> Repo.preload(board, columns: :cards)
    end
  end

  @doc """
  Fetches a board by the slug of its read-only link, preloaded like
  `get_board_by_slug/1`, or `nil`.
  """
  def get_board_by_view_slug(view_slug) when is_binary(view_slug) do
    case Repo.get_by(Board, view_slug: view_slug) do
      nil -> nil
      board -> Repo.preload(board, columns: :cards)
    end
  end

  @doc "Hides or reveals the vote counts for everyone on the board."
  def set_votes_hidden(%Board{} = board, hidden?) when is_boolean(hidden?) do
    board
    |> Ecto.Changeset.change(votes_hidden: hidden?)
    |> Repo.update()
    |> notify(board.id)
  end

  @doc """
  Remembers that `user_id` opened the board. A visitor who has used the edit
  link keeps edit access in their list even if they later open the read-only one.
  """
  def record_visit(%Board{id: board_id}, user_id, read_only?) when is_binary(user_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      Visit,
      [
        %{
          user_id: user_id,
          board_id: board_id,
          read_only: read_only?,
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:user_id, :board_id],
      on_conflict:
        from(v in Visit,
          update: [
            set: [
              updated_at: ^now,
              read_only: fragment("? AND EXCLUDED.read_only", v.read_only)
            ]
          ]
        )
    )

    :ok
  end

  @doc """
  Lists the boards `user_id` has opened, most recently opened first.

  Returns a list of `%{board: %Board{}, card_count: integer, read_only: boolean}`.
  """
  def list_visited_boards(user_id, limit \\ 12) when is_binary(user_id) do
    from(v in Visit,
      where: v.user_id == ^user_id,
      join: b in assoc(v, :board),
      left_join: c in assoc(b, :cards),
      group_by: [v.id, b.id],
      order_by: [desc: v.updated_at, desc: v.id],
      limit: ^limit,
      select: %{board: b, card_count: count(c.id), read_only: v.read_only}
    )
    |> Repo.all()
  end

  @doc "Creates a board with random slugs and the default columns."
  def create_board(attrs) do
    result =
      Repo.transact(fn ->
        with {:ok, board} <-
               %Board{slug: generate_slug(), view_slug: generate_slug()}
               |> Board.changeset(attrs)
               |> Repo.insert() do
          @default_columns
          |> Enum.with_index()
          |> Enum.each(fn {title, position} ->
            Repo.insert!(%Column{board_id: board.id, title: title, position: position})
          end)

          {:ok, board}
        end
      end)

    with {:ok, board} <- result do
      Phoenix.PubSub.broadcast(Huddle.PubSub, @boards_topic, {:board_created, board})
      {:ok, board}
    end
  end

  @doc "Returns a changeset for tracking board changes in forms."
  def change_board(%Board{} = board, attrs \\ %{}) do
    Board.changeset(board, attrs)
  end

  defp generate_slug do
    6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  ## Columns

  @doc "Fetches a column that belongs to the given board, or `nil`."
  def get_column(%Board{id: board_id}, id) do
    case parse_id(id) do
      nil -> nil
      column_id -> Repo.get_by(Column, id: column_id, board_id: board_id)
    end
  end

  @doc "Adds a column to the end of the board."
  def create_column(%Board{id: board_id}, attrs) do
    position =
      (Repo.aggregate(from(c in Column, where: c.board_id == ^board_id), :max, :position) || -1) +
        1

    %Column{board_id: board_id, position: position}
    |> Column.changeset(attrs)
    |> Repo.insert()
    |> notify(board_id)
  end

  @doc "Renames a column."
  def update_column(%Column{} = column, attrs) do
    column
    |> Column.changeset(attrs)
    |> Repo.update()
    |> notify(column.board_id)
  end

  @doc "Deletes a column and, through the database, all of its cards."
  def delete_column(%Column{} = column) do
    column
    |> Repo.delete()
    |> notify(column.board_id)
  end

  ## Cards

  @doc "Fetches a card that belongs to the given board, or `nil`."
  def get_card(%Board{id: board_id}, id) do
    case parse_id(id) do
      nil -> nil
      card_id -> Repo.get_by(Card, id: card_id, board_id: board_id)
    end
  end

  @doc """
  Adds a card to the bottom of a column.

  `user` is the session identity map with `"name"` and `"color"` keys.
  """
  def create_card(%Column{} = column, %{"name" => name, "color" => color}, attrs) do
    position =
      (Repo.aggregate(from(c in Card, where: c.column_id == ^column.id), :max, :position) || -1) +
        1

    %Card{
      board_id: column.board_id,
      column_id: column.id,
      position: position,
      author_name: name,
      author_color: color
    }
    |> Card.changeset(attrs)
    |> Repo.insert()
    |> notify(column.board_id)
  end

  @doc "Changes a card's title and label."
  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
    |> notify(card.board_id)
  end

  @doc "Returns a changeset for tracking card changes in forms."
  def change_card(%Card{} = card, attrs \\ %{}) do
    Card.changeset(card, attrs)
  end

  @doc """
  Adds `user_id`'s emoji reaction to a card, or removes it if it is already
  there. The row is locked while it changes, so reactions from several people
  at once are never lost.
  """
  def toggle_card_reaction(%Card{} = card, user_id, emoji) when is_binary(user_id) do
    if Reactions.valid?(emoji) do
      Repo.transact(fn ->
        case Repo.one(from(c in Card, where: c.id == ^card.id, lock: "FOR UPDATE")) do
          nil ->
            {:error, :not_found}

          fresh ->
            fresh
            |> Ecto.Changeset.change(reactions: Reactions.toggle(fresh.reactions, emoji, user_id))
            |> Repo.update()
        end
      end)
      |> notify(card.board_id)
    else
      {:error, :invalid_emoji}
    end
  end

  @doc "Deletes a card."
  def delete_card(%Card{} = card) do
    card
    |> Repo.delete()
    |> notify(card.board_id)
  end

  @doc "Adds one vote to a card. The increment happens in the database, so concurrent votes are never lost."
  def vote_card(%Card{} = card) do
    {1, _} = Repo.update_all(from(c in Card, where: c.id == ^card.id), inc: [votes: 1])
    broadcast_change(card.board_id)
    {:ok, %{card | votes: card.votes + 1}}
  end

  @doc """
  Moves a card to `index` within the column `to_column_id` (which may be the
  column it is already in) and renumbers the affected columns.

  `index` counts positions among the *other* cards of the target column, so
  `0` puts the card first. Out-of-range values are clamped.
  """
  def move_card(%Card{} = card, to_column_id, index) when is_integer(index) do
    with %Column{} = column <- Repo.get_by(Column, id: to_column_id, board_id: card.board_id) do
      {:ok, moved} =
        Repo.transact(fn ->
          other_ids =
            Repo.all(
              from(c in Card,
                where: c.column_id == ^column.id and c.id != ^card.id,
                order_by: [asc: c.position, asc: c.id],
                select: c.id
              )
            )

          index = index |> max(0) |> min(length(other_ids))

          card
          |> Ecto.Changeset.change(column_id: column.id)
          |> Repo.update!()

          other_ids |> List.insert_at(index, card.id) |> set_positions()

          if card.column_id != column.id, do: renumber(card.column_id)

          {:ok, Repo.get!(Card, card.id)}
        end)

      notify({:ok, moved}, card.board_id)
    else
      nil -> {:error, :not_found}
    end
  end

  defp renumber(column_id) do
    from(c in Card,
      where: c.column_id == ^column_id,
      order_by: [asc: c.position, asc: c.id],
      select: c.id
    )
    |> Repo.all()
    |> set_positions()
  end

  defp set_positions(card_ids) do
    card_ids
    |> Enum.with_index()
    |> Enum.each(fn {card_id, position} ->
      Repo.update_all(from(c in Card, where: c.id == ^card_id), set: [position: position])
    end)
  end

  ## Helpers

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
