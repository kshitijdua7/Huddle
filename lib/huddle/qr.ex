defmodule Huddle.QR do
  @moduledoc """
  A small QR code generator, enough for sharing a board link.

  It supports byte mode at error-correction level L for versions 1 to 5, which
  holds up to 106 bytes: plenty for a URL. Those versions use a single
  Reed-Solomon block and at most one alignment pattern, which keeps this short.

  `encode/1` returns `{:ok, rows}` where `rows` is a list of rows of booleans
  (`true` is a dark module), or `:error` if the text is too long.
  """

  import Bitwise

  # version => {total data codewords, error-correction codewords}
  @versions %{1 => {19, 7}, 2 => {34, 10}, 3 => {55, 15}, 4 => {80, 20}, 5 => {108, 26}}

  @doc "Encodes `text` as a QR code."
  def encode(text) when is_binary(text) do
    case Enum.find(1..5, &(byte_size(text) <= capacity(&1))) do
      nil -> :error
      version -> {:ok, build(text, version)}
    end
  end

  @doc "Renders the rows from `encode/1` as an SVG string with a quiet zone."
  def svg(rows, opts \\ []) do
    dark = Keyword.get(opts, :dark, "#111827")
    light = Keyword.get(opts, :light, "#ffffff")
    quiet = 3
    size = length(rows) + quiet * 2

    path =
      for {row, y} <- Enum.with_index(rows), {true, x} <- Enum.with_index(row), into: "" do
        "M#{x + quiet} #{y + quiet}h1v1h-1z"
      end

    ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{size} #{size}" ) <>
      ~s(shape-rendering="crispEdges" role="img" aria-label="QR code">) <>
      ~s(<rect width="#{size}" height="#{size}" fill="#{light}"/>) <>
      ~s(<path d="#{path}" fill="#{dark}"/></svg>)
  end

  # Byte mode needs a 4-bit mode marker and an 8-bit length before the data.
  defp capacity(version) do
    {data_codewords, _ec} = Map.fetch!(@versions, version)
    data_codewords - 2
  end

  defp build(text, version) do
    {data_count, ec_count} = Map.fetch!(@versions, version)
    data = data_codewords(text, data_count)
    codewords = data ++ reed_solomon(data, ec_count)
    size = 17 + 4 * version

    functions = function_modules(version, size)
    base = place_codewords(functions, codewords, size)

    {_penalty, modules} =
      0..7
      |> Enum.map(fn mask ->
        modules = base |> apply_mask(functions, mask, size) |> draw_format(mask, size)
        {penalty(modules, size), modules}
      end)
      |> Enum.min_by(&elem(&1, 0))

    for y <- 0..(size - 1) do
      for x <- 0..(size - 1), do: Map.get(modules, {x, y}, false)
    end
  end

  ## Data

  defp data_codewords(text, data_count) do
    bits = <<0b0100::4, byte_size(text)::8, text::binary>>
    room = data_count * 8 - bit_size(bits)
    terminator = min(4, room)
    bits = <<bits::bitstring, 0::size(terminator)>>
    padding = rem(8 - rem(bit_size(bits), 8), 8)
    bytes = :binary.bin_to_list(<<bits::bitstring, 0::size(padding)>>)

    pad_bytes = Stream.cycle([0xEC, 0x11]) |> Enum.take(data_count - length(bytes))
    bytes ++ pad_bytes
  end

  ## Reed-Solomon over GF(256), reducing polynomial 0x11D

  defp gf_multiply(x, y) do
    Enum.reduce(7..0//-1, 0, fn i, acc ->
      acc = bxor(acc <<< 1, (acc >>> 7) * 0x11D)
      bxor(acc, (y >>> i &&& 1) * x)
    end)
  end

  # The generator polynomial's coefficients, highest power first, without the
  # leading 1.
  defp generator(degree) do
    initial = List.duplicate(0, degree - 1) ++ [1]

    {coefficients, _root} =
      Enum.reduce(1..degree, {initial, 1}, fn _step, {coefficients, root} ->
        shifted = tl(coefficients) ++ [0]

        coefficients =
          coefficients
          |> Enum.zip(shifted)
          |> Enum.map(fn {coefficient, next} -> bxor(gf_multiply(coefficient, root), next) end)

        {coefficients, gf_multiply(root, 0x02)}
      end)

    coefficients
  end

  defp reed_solomon(data, ec_count) do
    generator = generator(ec_count)

    Enum.reduce(data, List.duplicate(0, ec_count), fn byte, [first | rest] ->
      factor = bxor(byte, first)

      (rest ++ [0])
      |> Enum.zip(generator)
      |> Enum.map(fn {value, coefficient} -> bxor(value, gf_multiply(coefficient, factor)) end)
    end)
  end

  ## Function patterns: finders, timing, alignment, and the format areas

  defp function_modules(version, size) do
    %{}
    |> draw_timing(size)
    |> draw_finder(3, 3, size)
    |> draw_finder(size - 4, 3, size)
    |> draw_finder(3, size - 4, size)
    |> draw_alignment(version)
    |> reserve_format(size)
  end

  defp draw_timing(modules, size) do
    Enum.reduce(0..(size - 1), modules, fn i, modules ->
      modules |> Map.put({6, i}, rem(i, 2) == 0) |> Map.put({i, 6}, rem(i, 2) == 0)
    end)
  end

  # A finder is three concentric squares plus a light separator ring.
  defp draw_finder(modules, cx, cy, size) do
    for dy <- -4..4,
        dx <- -4..4,
        x = cx + dx,
        y = cy + dy,
        x in 0..(size - 1),
        y in 0..(size - 1),
        reduce: modules do
      modules ->
        distance = max(abs(dx), abs(dy))
        Map.put(modules, {x, y}, distance != 2 and distance != 4)
    end
  end

  defp draw_alignment(modules, 1), do: modules

  defp draw_alignment(modules, version) do
    center = 4 * version + 10

    for dy <- -2..2, dx <- -2..2, reduce: modules do
      modules -> Map.put(modules, {center + dx, center + dy}, max(abs(dx), abs(dy)) != 1)
    end
  end

  # Mark the format-information modules as taken; `draw_format/3` fills them in.
  defp reserve_format(modules, size), do: draw_format(modules, 0, size)

  defp draw_format(modules, mask, size) do
    # Level L is 0b01. Fifteen bits: five of data, ten of BCH error correction.
    data = bor(0b01 <<< 3, mask)
    remainder = Enum.reduce(1..10, data, fn _, r -> bxor(r <<< 1, (r >>> 9) * 0x537) end)
    bits = bxor(bor(data <<< 10, remainder), 0x5412)
    bit = fn i -> (bits >>> i &&& 1) == 1 end

    modules = Enum.reduce(0..5, modules, &Map.put(&2, {8, &1}, bit.(&1)))

    modules =
      modules
      |> Map.put({8, 7}, bit.(6))
      |> Map.put({8, 8}, bit.(7))
      |> Map.put({7, 8}, bit.(8))

    modules = Enum.reduce(9..14, modules, &Map.put(&2, {14 - &1, 8}, bit.(&1)))
    modules = Enum.reduce(0..7, modules, &Map.put(&2, {size - 1 - &1, 8}, bit.(&1)))
    modules = Enum.reduce(8..14, modules, &Map.put(&2, {8, size - 15 + &1}, bit.(&1)))

    # The one module that is always dark.
    Map.put(modules, {8, size - 8}, true)
  end

  ## Data placement and masking

  # Codeword bits fill the free modules in a zigzag, two columns at a time,
  # from the bottom-right corner, skipping the vertical timing column.
  defp place_codewords(functions, codewords, size) do
    bits = for <<bit::1 <- :binary.list_to_bin(codewords)>>, do: bit == 1

    rights =
      (size - 1)
      |> Stream.iterate(&(&1 - 2))
      |> Stream.take_while(&(&1 >= 1))
      |> Enum.map(&if(&1 <= 6, do: &1 - 1, else: &1))

    positions =
      for right <- rights, vertical <- 0..(size - 1), j <- 0..1 do
        upward? = (right + 1 &&& 2) == 0
        {right - j, if(upward?, do: size - 1 - vertical, else: vertical)}
      end

    {modules, _left} =
      Enum.reduce(positions, {functions, bits}, fn position, {modules, bits} ->
        cond do
          Map.has_key?(functions, position) -> {modules, bits}
          bits == [] -> {Map.put(modules, position, false), []}
          true -> {Map.put(modules, position, hd(bits)), tl(bits)}
        end
      end)

    modules
  end

  defp apply_mask(modules, functions, mask, size) do
    for y <- 0..(size - 1),
        x <- 0..(size - 1),
        not Map.has_key?(functions, {x, y}),
        reduce: modules do
      modules ->
        if invert?(mask, x, y), do: Map.update!(modules, {x, y}, &(not &1)), else: modules
    end
  end

  defp invert?(0, x, y), do: rem(x + y, 2) == 0
  defp invert?(1, _x, y), do: rem(y, 2) == 0
  defp invert?(2, x, _y), do: rem(x, 3) == 0
  defp invert?(3, x, y), do: rem(x + y, 3) == 0
  defp invert?(4, x, y), do: rem(div(x, 3) + div(y, 2), 2) == 0
  defp invert?(5, x, y), do: rem(x * y, 2) + rem(x * y, 3) == 0
  defp invert?(6, x, y), do: rem(rem(x * y, 2) + rem(x * y, 3), 2) == 0
  defp invert?(7, x, y), do: rem(rem(x + y, 2) + rem(x * y, 3), 2) == 0

  ## Choosing a mask: lower penalty means easier to scan

  defp penalty(modules, size) do
    range = 0..(size - 1)
    rows = for y <- range, do: for(x <- range, do: Map.fetch!(modules, {x, y}))
    columns = for x <- range, do: for(y <- range, do: Map.fetch!(modules, {x, y}))

    runs = Enum.sum(Enum.map(rows ++ columns, &run_penalty/1))

    blocks =
      for y <- 0..(size - 2), x <- 0..(size - 2), reduce: 0 do
        total ->
          color = Map.fetch!(modules, {x, y})

          same? =
            Map.fetch!(modules, {x + 1, y}) == color and
              Map.fetch!(modules, {x, y + 1}) == color and
              Map.fetch!(modules, {x + 1, y + 1}) == color

          if same?, do: total + 3, else: total
      end

    dark = Enum.count(modules, fn {_position, dark?} -> dark? end)
    balance = div(abs(dark * 20 - size * size * 10), size * size) * 10

    runs + blocks + balance
  end

  # Runs of five or more modules of one colour in a line.
  defp run_penalty(line) do
    line
    |> Enum.chunk_by(& &1)
    |> Enum.map(&length/1)
    |> Enum.filter(&(&1 >= 5))
    |> Enum.map(&(&1 - 2))
    |> Enum.sum()
  end
end
