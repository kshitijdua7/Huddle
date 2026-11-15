defmodule Huddle.QRTest do
  use ExUnit.Case, async: true

  alias Huddle.QR

  # The expected rows were produced by this module and checked by scanning the
  # code with a QR reader, so this guards against accidental changes.
  test "encode/1 produces the known code for a short text" do
    assert {:ok, rows} = QR.encode("hi")

    assert render(rows) == """
           #######..#..#.#######
           #.....#.#..#..#.....#
           #.###.#..#....#.###.#
           #.###.#.#..#..#.###.#
           #.###.#...###.#.###.#
           #.....#.###.#.#.....#
           #######.#.#.#.#######
           ..........###........
           #####.####..##.#.#.#.
           #.#..#....#.#..#....#
           .#...###..##.#..####.
           ####.#.#.......##.#..
           #.#.###..#.#.#..#.#.#
           ........#.#####..#..#
           #######.#...#.##...#.
           #.....#..######..#..#
           #.###.#.#.#.#..#..#..
           #.###.#.##..#..#..#..
           #.###.#.#..#.#..###..
           #.....#.##.....##.#..
           #######.####.#..####.
           """
  end

  test "the size grows with the text and every row is square" do
    for {text, size} <- [
          {"hi", 21},
          {"http://localhost:4000/b/2aX2TfY6", 25},
          {String.duplicate("a", 106), 37}
        ] do
      assert {:ok, rows} = QR.encode(text)
      assert length(rows) == size
      assert Enum.all?(rows, &(length(&1) == size))
    end
  end

  test "encode/1 refuses text that does not fit" do
    assert QR.encode(String.duplicate("a", 107)) == :error
  end

  test "svg/1 draws one square per dark module inside a quiet zone" do
    {:ok, rows} = QR.encode("hi")
    svg = QR.svg(rows)
    dark = rows |> List.flatten() |> Enum.count(& &1)

    assert svg =~ ~s(viewBox="0 0 27 27")
    assert length(String.split(svg, "h1v1h-1z")) - 1 == dark
  end

  defp render(rows) do
    Enum.map_join(rows, fn row ->
      Enum.map_join(row, &if(&1, do: "#", else: ".")) <> "\n"
    end)
  end
end
