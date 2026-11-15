defmodule Huddle.Chat do
  @moduledoc """
  The Chat context: the message history of each board.

  New messages are broadcast as `{:new_message, message}` on the board's topic.
  """

  import Ecto.Query, warn: false

  alias Huddle.Boards
  alias Huddle.Boards.Board
  alias Huddle.Chat.Message
  alias Huddle.{Reactions, Repo}

  @system_color "#94a3b8"

  @doc "Returns the latest `limit` messages of a board, oldest first."
  def list_messages(%Board{id: board_id}, limit \\ 100) do
    from(m in Message,
      where: m.board_id == ^board_id,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Posts a message written by `user` (the session identity map)."
  def create_message(%Board{id: board_id}, %{"name" => name, "color" => color}, attrs) do
    %Message{board_id: board_id, kind: "user", author_name: name, author_color: color}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> broadcast_new()
  end

  @doc "Posts an activity note, for example when a card moves or a timer starts."
  def create_system_message(%Board{id: board_id}, body) when is_binary(body) do
    %Message{
      board_id: board_id,
      kind: "system",
      author_name: "Huddle",
      author_color: @system_color
    }
    |> Message.changeset(%{body: body})
    |> Repo.insert()
    |> broadcast_new()
  end

  @doc "Fetches a message that belongs to the given board, or `nil`."
  def get_message(%Board{id: board_id}, id) do
    case id do
      id when is_integer(id) -> Repo.get_by(Message, id: id, board_id: board_id)
      id when is_binary(id) -> get_message_by_string_id(board_id, id)
      _other -> nil
    end
  end

  defp get_message_by_string_id(board_id, id) do
    case Integer.parse(id) do
      {int, ""} -> Repo.get_by(Message, id: int, board_id: board_id)
      _other -> nil
    end
  end

  @doc """
  Adds or removes `user_id`'s emoji reaction on a message and broadcasts
  `{:message_updated, message}`.
  """
  def toggle_reaction(%Message{} = message, user_id, emoji) when is_binary(user_id) do
    if Reactions.valid?(emoji) do
      result =
        Repo.transact(fn ->
          case Repo.one(from(m in Message, where: m.id == ^message.id, lock: "FOR UPDATE")) do
            nil ->
              {:error, :not_found}

            fresh ->
              fresh
              |> Ecto.Changeset.change(
                reactions: Reactions.toggle(fresh.reactions, emoji, user_id)
              )
              |> Repo.update()
          end
        end)

      with {:ok, updated} <- result do
        Phoenix.PubSub.broadcast(
          Huddle.PubSub,
          Boards.topic(updated.board_id),
          {:message_updated, updated}
        )

        {:ok, updated}
      end
    else
      {:error, :invalid_emoji}
    end
  end

  defp broadcast_new({:ok, message}) do
    Phoenix.PubSub.broadcast(
      Huddle.PubSub,
      Boards.topic(message.board_id),
      {:new_message, message}
    )

    {:ok, message}
  end

  defp broadcast_new(error), do: error
end
