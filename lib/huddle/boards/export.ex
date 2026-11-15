defmodule Huddle.Boards.Export do
  @moduledoc """
  Turns a board (with columns and cards preloaded) into Markdown or CSV, for
  keeping a record once a meeting is over.

  Vote counts are left out while the board's votes are hidden.
  """

  alias Huddle.Boards.Board
  alias Huddle.Reactions

  @doc "The board as a Markdown document."
  def to_markdown(%Board{} = board) do
    columns =
      Enum.map_join(board.columns, "\n", fn column ->
        cards =
          case column.cards do
            [] -> "_No cards_\n"
            cards -> Enum.map_join(cards, &markdown_card(&1, board))
          end

        "## #{column.title} (#{length(column.cards)})\n\n#{cards}"
      end)

    "# #{board.name}\n\n_Exported from Huddle on #{Date.utc_today()}_\n\n#{columns}"
  end

  defp markdown_card(card, board) do
    details =
      [
        card.author_name,
        if(!board.votes_hidden and card.votes > 0, do: pluralize(card.votes, "vote")),
        reactions_text(card)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    label = if card.label, do: "**[#{card.label}]** ", else: ""
    "- #{label}#{card.title} — #{details}\n"
  end

  @doc "The board as CSV, one row per card."
  def to_csv(%Board{} = board) do
    header = ~w(column position title label author votes reactions created_at)

    rows =
      for column <- board.columns, card <- column.cards do
        [
          column.title,
          card.position + 1,
          card.title,
          card.label || "",
          card.author_name,
          if(board.votes_hidden, do: "", else: card.votes),
          reactions_text(card),
          DateTime.to_iso8601(card.inserted_at)
        ]
      end

    Enum.map_join([header | rows], "", fn row ->
      Enum.map_join(row, ",", &csv_field/1) <> "\r\n"
    end)
  end

  defp reactions_text(card) do
    card.reactions
    |> Reactions.summarize(nil)
    |> Enum.map_join(" ", &"#{&1.emoji} #{&1.count}")
  end

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(count, word), do: "#{count} #{word}s"

  # Quote every field, and neutralise values a spreadsheet would run as a formula.
  defp csv_field(value) do
    text = to_string(value)
    text = if String.starts_with?(text, ["=", "+", "-", "@"]), do: "'" <> text, else: text
    ~s("#{String.replace(text, ~s("), ~s(""))}")
  end
end
