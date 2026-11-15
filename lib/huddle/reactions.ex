defmodule Huddle.Reactions do
  @moduledoc """
  Emoji reactions on cards and chat messages.

  Reactions are stored on the row itself as a map of emoji to the ids of the
  people who reacted: `%{"👍" => ["user-1", "user-2"]}`.
  """

  @emojis ~w(👍 ❤️ 🎉 😂 🤔 👀)

  @doc "The emojis people can react with, in display order."
  def emojis, do: @emojis

  def valid?(emoji), do: emoji in @emojis

  @doc "Adds `user_id` to the emoji's list, or removes it if it is already there."
  def toggle(reactions, emoji, user_id) when is_map(reactions) do
    user_ids = Map.get(reactions, emoji, [])

    case if(user_id in user_ids, do: user_ids -- [user_id], else: user_ids ++ [user_id]) do
      [] -> Map.delete(reactions, emoji)
      user_ids -> Map.put(reactions, emoji, user_ids)
    end
  end

  @doc """
  The reactions as a list of `%{emoji, index, count, mine?}` in display order,
  leaving out emojis nobody picked.
  """
  def summarize(reactions, user_id) when is_map(reactions) do
    for {emoji, index} <- Enum.with_index(@emojis),
        user_ids = Map.get(reactions, emoji, []),
        user_ids != [] do
      %{emoji: emoji, index: index, count: length(user_ids), mine?: user_id in user_ids}
    end
  end
end
