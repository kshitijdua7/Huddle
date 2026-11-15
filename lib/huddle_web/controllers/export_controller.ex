defmodule HuddleWeb.ExportController do
  @moduledoc """
  Downloads a board as Markdown or CSV. Both the edit link and the read-only
  link can export.
  """
  use HuddleWeb, :controller

  alias Huddle.Boards
  alias Huddle.Boards.Export

  def edit_link(conn, %{"slug" => slug, "format" => format}) do
    export(conn, Boards.get_board_by_slug(slug), format)
  end

  def view_link(conn, %{"view_slug" => view_slug, "format" => format}) do
    export(conn, Boards.get_board_by_view_slug(view_slug), format)
  end

  defp export(conn, %Boards.Board{} = board, "md") do
    send_download(conn, {:binary, Export.to_markdown(board)},
      filename: filename(board, "md"),
      content_type: "text/markdown",
      charset: "utf-8"
    )
  end

  defp export(conn, %Boards.Board{} = board, "csv") do
    # The byte-order mark makes spreadsheet apps read the file as UTF-8.
    send_download(conn, {:binary, "﻿" <> Export.to_csv(board)},
      filename: filename(board, "csv"),
      content_type: "text/csv",
      charset: "utf-8"
    )
  end

  defp export(conn, _board_or_nil, _format) do
    conn
    |> put_flash(:error, "That export isn't available.")
    |> redirect(to: ~p"/")
  end

  defp filename(board, extension) do
    name =
      board.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    "#{if name == "", do: "board", else: name}.#{extension}"
  end
end
