defmodule Codrift.TUI.VT100 do
  @moduledoc """
  Pure Elixir VT100/ANSI terminal emulator for rendering PTY output inside
  an ex_ratatui `Paragraph` widget.

  ## Architecture

  Mirrors the tmux `window_pane` model:

  1. `new/2` — allocate a virtual screen (width × height cell grid)
  2. `process/2` — feed raw PTY bytes; updates cursor, cells, and style
  3. `to_text/1` — convert the cell grid to `%ExRatatui.Text{}` for rendering
  4. `resize/3` — notify the emulator of dimension changes (also send TIOCSWINSZ
     to the process via `erlexec`'s `:exec.winsz/3`)

  ## Supported sequences

  - SGR colors and modifiers (`\\e[...m`)
  - Cursor movement: absolute (`H`/`f`), relative (`A B C D`), column (`G`)
  - Erase: screen (`J 0/1/2`), line (`K 0/1/2`)
  - Save/restore cursor (`\\e7`/`\\e8` and `\\e[s`/`\\e[u`)
  - Set scroll region (`r`)
  - Alternate screen toggle (`?1049h/l` — treated as clear)
  - Carriage return, line feed, backspace, tab
  """

  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}

  @default_style %Style{}
  @empty_char " "

  @type cell :: {String.t(), Style.t()}
  @type grid :: %{non_neg_integer() => %{non_neg_integer() => cell()}}

  defstruct [
    :width,
    :height,
    :cells,
    :cursor_row,
    :cursor_col,
    :saved_cursor,
    :style,
    :scroll_top,
    :scroll_bottom
  ]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          cells: grid(),
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          saved_cursor: {non_neg_integer(), non_neg_integer()},
          style: Style.t(),
          scroll_top: non_neg_integer(),
          scroll_bottom: non_neg_integer()
        }

  @doc "Creates a new virtual screen with all cells blank."
  def new(width, height) do
    %__MODULE__{
      width: max(width, 1),
      height: max(height, 1),
      cells: %{},
      cursor_row: 0,
      cursor_col: 0,
      saved_cursor: {0, 0},
      style: @default_style,
      scroll_top: 0,
      scroll_bottom: max(height - 1, 0)
    }
  end

  @doc "Resizes the virtual screen, discarding cells outside the new bounds."
  def resize(%__MODULE__{} = screen, width, height) do
    %{screen | width: max(width, 1), height: max(height, 1), scroll_bottom: max(height - 1, 0)}
  end

  @doc "Feeds raw PTY bytes into the emulator and returns the updated screen."
  def process(%__MODULE__{} = screen, data) when is_binary(data) do
    process_bytes(screen, data)
  end

  @doc "Converts the current screen state to an `%ExRatatui.Text{}` ready for `Paragraph`."
  def to_text(%__MODULE__{} = screen) do
    lines =
      Enum.map(0..(screen.height - 1), fn row ->
        row_cells = Map.get(screen.cells, row, %{})
        %Line{spans: row_to_spans(row_cells, screen.width)}
      end)

    %Text{lines: lines}
  end

  defp row_to_spans(row_cells, _width) do
    if map_size(row_cells) == 0 do
      []
    else
      last_col = Enum.max(Map.keys(row_cells))

      0..last_col
      |> Enum.map(fn col -> Map.get(row_cells, col, {@empty_char, @default_style}) end)
      |> group_spans()
    end
  end

  defp group_spans([]), do: [%Span{content: " "}]

  defp group_spans(cells) do
    cells
    |> Enum.chunk_by(fn {_, style} -> style end)
    |> Enum.map(fn group ->
      {_, style} = hd(group)
      content = Enum.map_join(group, fn {ch, _} -> ch end)
      %Span{content: content, style: style}
    end)
  end

  # ── Byte-level parser ─────────────────────────────────────────────────────

  defp process_bytes(screen, ""), do: screen

  # OSC sequences: \e]...BEL or \e]...\e\\ — ignore entirely
  defp process_bytes(screen, <<"\e]", rest::binary>>) do
    rest |> skip_until_osc_end() |> then(&process_bytes(screen, &1))
  end

  # CSI: \e[ params final — private mode (\e[?...) handled separately
  defp process_bytes(screen, <<"\e[", rest::binary>>) do
    case parse_csi(rest) do
      {:private, params, final, tail} ->
        screen |> apply_private_csi(params, final) |> process_bytes(tail)

      {params, final, tail} ->
        screen |> apply_csi(params, final) |> process_bytes(tail)
    end
  end

  # Two-char ESC sequences
  defp process_bytes(screen, <<"\e7", rest::binary>>),
    do: process_bytes(save_cursor(screen), rest)

  defp process_bytes(screen, <<"\e8", rest::binary>>),
    do: process_bytes(restore_cursor(screen), rest)

  defp process_bytes(screen, <<"\eM", rest::binary>>),
    do: process_bytes(reverse_index(screen), rest)

  # Unknown two-char ESC — skip
  defp process_bytes(screen, <<"\e", _::utf8, rest::binary>>), do: process_bytes(screen, rest)

  # Lone ESC at end of buffer — skip
  defp process_bytes(screen, <<"\e">>), do: screen

  # Control characters
  defp process_bytes(screen, <<"\r", rest::binary>>),
    do: process_bytes(%{screen | cursor_col: 0}, rest)

  defp process_bytes(screen, <<"\n", rest::binary>>) do
    process_bytes(advance_line(screen), rest)
  end

  defp process_bytes(screen, <<"\b", rest::binary>>) do
    process_bytes(%{screen | cursor_col: max(screen.cursor_col - 1, 0)}, rest)
  end

  defp process_bytes(screen, <<"\t", rest::binary>>) do
    next_tab = div(screen.cursor_col, 8) * 8 + 8
    process_bytes(%{screen | cursor_col: min(next_tab, screen.width - 1)}, rest)
  end

  # Skip NUL bytes
  defp process_bytes(screen, <<0, rest::binary>>), do: process_bytes(screen, rest)

  # Printable UTF-8 grapheme
  defp process_bytes(screen, <<char::utf8, rest::binary>>) when char >= 0x20 do
    process_bytes(write_char(screen, <<char::utf8>>), rest)
  end

  # Other control bytes — skip
  defp process_bytes(screen, <<_::8, rest::binary>>), do: process_bytes(screen, rest)

  # ── CSI dispatch ──────────────────────────────────────────────────────────

  defp apply_csi(screen, params, ?H), do: cursor_position(screen, params)
  defp apply_csi(screen, params, ?f), do: cursor_position(screen, params)

  defp apply_csi(screen, params, ?A) do
    n = p(params, 0, 1)
    %{screen | cursor_row: max(screen.cursor_row - n, screen.scroll_top)}
  end

  defp apply_csi(screen, params, ?B) do
    n = p(params, 0, 1)
    %{screen | cursor_row: min(screen.cursor_row + n, screen.scroll_bottom)}
  end

  defp apply_csi(screen, params, ?C) do
    n = p(params, 0, 1)
    %{screen | cursor_col: min(screen.cursor_col + n, screen.width - 1)}
  end

  defp apply_csi(screen, params, ?D) do
    n = p(params, 0, 1)
    %{screen | cursor_col: max(screen.cursor_col - n, 0)}
  end

  defp apply_csi(screen, params, ?G) do
    col = p(params, 0, 1) - 1
    %{screen | cursor_col: clamp(col, 0, screen.width - 1)}
  end

  defp apply_csi(screen, params, ?J) do
    case p(params, 0, 0) do
      0 -> erase_below(screen)
      1 -> erase_above(screen)
      2 -> clear_screen(screen)
      _ -> screen
    end
  end

  defp apply_csi(screen, params, ?K) do
    case p(params, 0, 0) do
      0 -> erase_line_right(screen)
      1 -> erase_line_left(screen)
      2 -> erase_entire_line(screen)
      _ -> screen
    end
  end

  defp apply_csi(screen, params, ?m), do: %{screen | style: apply_sgr(params, screen.style)}
  defp apply_csi(screen, _params, ?s), do: save_cursor(screen)
  defp apply_csi(screen, _params, ?u), do: restore_cursor(screen)

  defp apply_csi(screen, params, ?r) do
    top = max(p(params, 0, 1) - 1, 0)
    bottom = min(p(params, 1, screen.height) - 1, screen.height - 1)
    %{screen | scroll_top: top, scroll_bottom: bottom, cursor_row: 0, cursor_col: 0}
  end

  defp apply_csi(screen, _params, _final), do: screen

  defp apply_private_csi(screen, params, ?h) do
    if List.first(params) == 1049, do: clear_screen(screen), else: screen
  end

  defp apply_private_csi(screen, _params, _final), do: screen

  # ── Cursor and edit operations ────────────────────────────────────────────

  defp cursor_position(screen, params) do
    row = clamp(p(params, 0, 1) - 1, 0, screen.height - 1)
    col = clamp(p(params, 1, 1) - 1, 0, screen.width - 1)
    %{screen | cursor_row: row, cursor_col: col}
  end

  defp write_char(screen, char) do
    row = screen.cursor_row
    col = screen.cursor_col

    if col >= screen.width do
      screen
      |> advance_line()
      |> then(fn s -> write_char(%{s | cursor_col: 0}, char) end)
    else
      row_cells = Map.get(screen.cells, row, %{})
      new_row = Map.put(row_cells, col, {char, screen.style})
      new_cells = Map.put(screen.cells, row, new_row)
      %{screen | cells: new_cells, cursor_col: col + 1}
    end
  end

  defp advance_line(%{cursor_row: row, scroll_bottom: bottom} = screen) when row >= bottom do
    scroll_up(screen, 1)
  end

  defp advance_line(screen) do
    %{screen | cursor_row: screen.cursor_row + 1}
  end

  defp reverse_index(%{cursor_row: row, scroll_top: top} = screen) when row <= top do
    scroll_down(screen, 1)
  end

  defp reverse_index(screen) do
    %{screen | cursor_row: screen.cursor_row - 1}
  end

  defp scroll_up(screen, n) do
    top = screen.scroll_top
    bottom = screen.scroll_bottom

    new_cells =
      Enum.reduce(top..(bottom - n), screen.cells, fn row, cells ->
        Map.put(cells, row, Map.get(cells, row + n, %{}))
      end)

    new_cells =
      Enum.reduce((bottom - n + 1)..bottom, new_cells, fn row, cells ->
        Map.put(cells, row, %{})
      end)

    %{screen | cells: new_cells, cursor_row: screen.scroll_bottom}
  end

  defp scroll_down(screen, n) do
    top = screen.scroll_top
    bottom = screen.scroll_bottom

    new_cells =
      Enum.reduce(bottom..top//-1, screen.cells, fn row, cells ->
        if row - n >= top do
          Map.put(cells, row, Map.get(cells, row - n, %{}))
        else
          Map.put(cells, row, %{})
        end
      end)

    %{screen | cells: new_cells, cursor_row: screen.scroll_top}
  end

  defp save_cursor(screen) do
    %{screen | saved_cursor: {screen.cursor_row, screen.cursor_col}}
  end

  defp restore_cursor(screen) do
    {row, col} = screen.saved_cursor
    %{screen | cursor_row: row, cursor_col: col}
  end

  defp clear_screen(screen) do
    %{screen | cells: %{}, cursor_row: 0, cursor_col: 0}
  end

  defp erase_below(screen) do
    row = screen.cursor_row

    new_cells =
      screen.cells
      |> Map.update(row, %{}, fn row_map ->
        Map.drop(row_map, Enum.to_list(screen.cursor_col..(screen.width - 1)))
      end)
      |> Map.drop(Enum.to_list((row + 1)..(screen.height - 1)))

    %{screen | cells: new_cells}
  end

  defp erase_above(screen) do
    row = screen.cursor_row

    new_cells =
      screen.cells
      |> Map.update(row, %{}, fn row_map ->
        Map.drop(row_map, Enum.to_list(0..screen.cursor_col))
      end)
      |> Map.drop(Enum.to_list(0..(row - 1)))

    %{screen | cells: new_cells}
  end

  defp erase_line_right(screen) do
    update_row(screen, screen.cursor_row, fn row_map ->
      Map.drop(row_map, Enum.to_list(screen.cursor_col..(screen.width - 1)))
    end)
  end

  defp erase_line_left(screen) do
    update_row(screen, screen.cursor_row, fn row_map ->
      Map.drop(row_map, Enum.to_list(0..screen.cursor_col))
    end)
  end

  defp erase_entire_line(screen) do
    %{screen | cells: Map.put(screen.cells, screen.cursor_row, %{})}
  end

  defp update_row(screen, row, fun) do
    new_cells = Map.update(screen.cells, row, %{}, fun)
    %{screen | cells: new_cells}
  end

  # ── SGR (colors/style) ────────────────────────────────────────────────────

  defp apply_sgr(params, style) do
    codes = params |> List.flatten() |> parse_int_list()
    reduce_sgr(codes, style)
  end

  defp reduce_sgr([], style), do: style
  defp reduce_sgr([0 | rest], _style), do: reduce_sgr(rest, @default_style)
  defp reduce_sgr([1 | rest], style), do: reduce_sgr(rest, add_mod(style, :bold))
  defp reduce_sgr([2 | rest], style), do: reduce_sgr(rest, add_mod(style, :dim))
  defp reduce_sgr([3 | rest], style), do: reduce_sgr(rest, add_mod(style, :italic))
  defp reduce_sgr([4 | rest], style), do: reduce_sgr(rest, add_mod(style, :underlined))
  defp reduce_sgr([9 | rest], style), do: reduce_sgr(rest, add_mod(style, :crossed_out))
  defp reduce_sgr([22 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:bold, :dim]))
  defp reduce_sgr([39 | rest], style), do: reduce_sgr(rest, %{style | fg: nil})
  defp reduce_sgr([49 | rest], style), do: reduce_sgr(rest, %{style | bg: nil})

  defp reduce_sgr([n | rest], style) when n in 30..37,
    do: reduce_sgr(rest, %{style | fg: ansi_color(n - 30)})

  defp reduce_sgr([n | rest], style) when n in 90..97,
    do: reduce_sgr(rest, %{style | fg: bright_color(n - 90)})

  defp reduce_sgr([n | rest], style) when n in 40..47,
    do: reduce_sgr(rest, %{style | bg: ansi_color(n - 40)})

  defp reduce_sgr([n | rest], style) when n in 100..107,
    do: reduce_sgr(rest, %{style | bg: bright_color(n - 100)})

  defp reduce_sgr([38, 5, n | rest], style), do: reduce_sgr(rest, %{style | fg: {:indexed, n}})

  defp reduce_sgr([38, 2, r, g, b | rest], style),
    do: reduce_sgr(rest, %{style | fg: {:rgb, r, g, b}})

  defp reduce_sgr([48, 5, n | rest], style), do: reduce_sgr(rest, %{style | bg: {:indexed, n}})

  defp reduce_sgr([48, 2, r, g, b | rest], style),
    do: reduce_sgr(rest, %{style | bg: {:rgb, r, g, b}})

  defp reduce_sgr([_ | rest], style), do: reduce_sgr(rest, style)

  defp ansi_color(0), do: :black
  defp ansi_color(1), do: :red
  defp ansi_color(2), do: :green
  defp ansi_color(3), do: :yellow
  defp ansi_color(4), do: :blue
  defp ansi_color(5), do: :magenta
  defp ansi_color(6), do: :cyan
  defp ansi_color(7), do: :white

  defp bright_color(0), do: :dark_gray
  defp bright_color(1), do: :light_red
  defp bright_color(2), do: :light_green
  defp bright_color(3), do: :light_yellow
  defp bright_color(4), do: :light_blue
  defp bright_color(5), do: :light_magenta
  defp bright_color(6), do: :light_cyan
  defp bright_color(7), do: :white

  defp add_mod(style, mod), do: %{style | modifiers: Enum.uniq([mod | style.modifiers])}
  defp rem_mods(style, mods), do: %{style | modifiers: style.modifiers -- mods}

  # ── CSI parsing ───────────────────────────────────────────────────────────

  defp parse_csi(<<"?", rest::binary>>) do
    {param_bytes, after_params} = split_csi_numeric(rest, [])

    case after_params do
      <<final::8, tail::binary>> when final in 0x40..0x7E ->
        {:private, parse_csi_params(param_bytes), final, tail}

      _ ->
        {:private, [], 0, after_params}
    end
  end

  defp parse_csi(data) do
    {param_bytes, rest} = split_csi(data, [])

    case rest do
      <<final::8, tail::binary>> when final in 0x40..0x7E ->
        {parse_csi_params(param_bytes), final, tail}

      _ ->
        {[], 0, rest}
    end
  end

  # Captures 0x30–0x3B: digits 0–9 and semicolon (excludes ? and other private chars)
  defp split_csi_numeric(<<byte::8, rest::binary>>, acc) when byte in 0x30..0x3B do
    split_csi_numeric(rest, [byte | acc])
  end

  defp split_csi_numeric(rest, acc), do: {Enum.reverse(acc), rest}

  # Captures 0x30–0x3F: all param characters including ? < > = — used for normal params
  defp split_csi(<<byte::8, rest::binary>>, acc) when byte in 0x30..0x3F do
    split_csi(rest, [byte | acc])
  end

  defp split_csi(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_csi_params(bytes) do
    bytes
    |> List.to_string()
    |> String.split(";")
    |> Enum.map(&parse_num_or_empty/1)
  end

  defp parse_num_or_empty(""), do: nil

  defp parse_num_or_empty(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp p(params, idx, default) do
    case Enum.at(params, idx) do
      nil -> default
      0 -> default
      n when is_integer(n) -> n
      _ -> default
    end
  end

  defp parse_int_list(params) do
    Enum.flat_map(params, fn
      nil -> [0]
      n when is_integer(n) -> [n]
      _ -> [0]
    end)
  end

  defp skip_until_osc_end(""), do: ""
  defp skip_until_osc_end(<<7, rest::binary>>), do: rest
  defp skip_until_osc_end(<<"\e\\", rest::binary>>), do: rest
  defp skip_until_osc_end(<<_::8, rest::binary>>), do: skip_until_osc_end(rest)

  defp clamp(v, lo, hi), do: min(max(v, lo), hi)
end
