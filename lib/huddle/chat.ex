defmodule Huddle.Chat do
  @moduledoc """
  The Chat context: the message history of each board.

  New messages are broadcast as `{:new_message, message}` on the board's topic.
  """

  import Ecto.Query, warn: false

  alias Huddle.Boards
  alias Huddle.Boards.Board
  alias Huddle.Chat.Message
  alias Huddle.Repo

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
    %Message{board_id: board_id, kind: "system", author_name: "Huddle", author_color: @system_color}
    |> Message.changeset(%{body: body})
    |> Repo.insert()
    |> broadcast_new()
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
