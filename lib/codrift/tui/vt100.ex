defmodule Codrift.TUI.VT100 do
  @moduledoc """
  Pure Elixir VT100/ANSI terminal emulator for rendering PTY output inside
  an ex_ratatui `Paragraph` widget.

  ## Architecture

  Mirrors the tmux `window_pane` model:

  1. `new/2` — allocate a virtual screen (width × height cell grid)
  2. `process/2` — feed raw PTY bytes; updates cursor, cells, and style
  3. `to_text/2` — convert the cell grid to `%ExRatatui.Text{}` for rendering
  4. `resize/3` — notify the emulator of dimension changes

  ## Supported sequences

  - SGR colors and modifiers (`\\e[...m`)
  - Cursor movement: absolute (`H`/`f`/`d`), relative (`A B C D`), column (`G`)
  - Erase: screen (`J 0/1/2`), line (`K 0/1/2`), characters (`X`)
  - Character insert/delete (`@`/`P`)
  - Scroll region (`r`)
  - Save/restore cursor (`\\e7`/`\\e8` and `\\e[s`/`\\e[u`)
  - Alternate screen toggle (`?1049h/l` — treated as clear)
  - Cursor visibility (`?25h/l`)
  - Carriage return, line feed, backspace, tab

  ## Not implemented (safe to add later once scroll-region tracking is validated)

  - IL/DL (`L`/`M`) — insert/delete lines; requires accurate scroll-region sync
  - SU/SD (`S`/`T`) — scroll viewport; same caveat
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
    :cursor_visible,
    :saved_cursor,
    :style,
    :scroll_top,
    :scroll_bottom,
    :incomplete
  ]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          cells: grid(),
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          cursor_visible: boolean(),
          saved_cursor: {non_neg_integer(), non_neg_integer()},
          style: Style.t(),
          scroll_top: non_neg_integer(),
          scroll_bottom: non_neg_integer(),
          incomplete: binary()
        }

  @doc "Creates a new virtual screen with all cells blank."
  def new(width, height) do
    %__MODULE__{
      width: max(width, 1),
      height: max(height, 1),
      cells: %{},
      cursor_row: 0,
      cursor_col: 0,
      cursor_visible: true,
      saved_cursor: {0, 0},
      style: @default_style,
      scroll_top: 0,
      scroll_bottom: max(height - 1, 0),
      incomplete: ""
    }
  end

  @doc "Resizes the virtual screen, discarding cells outside the new bounds."
  def resize(%__MODULE__{} = screen, width, height) do
    w = max(width, 1)
    h = max(height, 1)
    {sr, sc} = screen.saved_cursor

    %{
      screen
      | width: w,
        height: h,
        scroll_top: min(screen.scroll_top, h - 1),
        scroll_bottom: h - 1,
        cursor_row: min(screen.cursor_row, h - 1),
        cursor_col: min(screen.cursor_col, w - 1),
        saved_cursor: {min(sr, h - 1), min(sc, w - 1)}
    }
  end

  @doc "Feeds raw PTY bytes into the emulator and returns the updated screen."
  def process(%__MODULE__{} = screen, data) when is_binary(data) do
    combined = screen.incomplete <> data
    {complete, leftover} = split_at_incomplete(combined)
    updated = process_bytes(screen, complete)
    %{updated | incomplete: leftover}
  end

  @doc """
  Returns the index of the first row that contains at least one non-space
  character. Useful for skipping leading blank rows (e.g. from a shell
  prompt's `add_newline` separator) when setting the initial scroll offset.
  Returns 0 when no blank leading rows are found or the screen is empty.
  """
  def first_content_row(%__MODULE__{} = screen) do
    Enum.find(0..(screen.height - 1), 0, fn row ->
      row_cells = Map.get(screen.cells, row, %{})
      Enum.any?(row_cells, fn {_col, {ch, _style}} -> ch != " " end)
    end)
  end

  @doc """
  Converts the current screen state to an `%ExRatatui.Text{}` ready for `Paragraph`.

  Pass `show_cursor: true` to render the cursor as a reversed cell. The cursor is
  only shown if the screen has not hidden it via `\\e[?25l`.
  """
  def to_text(%__MODULE__{} = screen, show_cursor \\ false) do
    display_cursor = show_cursor and screen.cursor_visible

    lines =
      Enum.map(0..(screen.height - 1), fn row ->
        row_cells = Map.get(screen.cells, row, %{})

        cells =
          if display_cursor and row == screen.cursor_row do
            col = screen.cursor_col
            {ch, style} = Map.get(row_cells, col, {@empty_char, @default_style})
            cursor_style = %{style | modifiers: Enum.uniq([:reversed | style.modifiers])}
            Map.put(row_cells, col, {ch, cursor_style})
          else
            row_cells
          end

        %Line{spans: row_to_spans(cells, screen.width)}
      end)

    %Text{lines: lines}
  end

  defp row_to_spans(row_cells, width) do
    0..(width - 1)
    |> Enum.map(fn col -> Map.get(row_cells, col, {@empty_char, @default_style}) end)
    |> group_spans()
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

  # ── Incomplete-sequence carry buffer ─────────────────────────────────────
  #
  # PTY output arrives in arbitrary chunks that can be split mid-escape-sequence.
  # We scan the end of each combined (carry + new) binary for an incomplete ESC
  # sequence and hold it over for the next call rather than dropping it or
  # misinterpreting the continuation bytes as literal text.

  defp split_at_incomplete(data) do
    sz = byte_size(data)
    scan_start = max(sz - 1032, 0)

    case find_last_esc(data, sz - 1, scan_start) do
      nil ->
        {data, ""}

      pos ->
        tail = binary_part(data, pos, sz - pos)

        if incomplete_esc?(tail),
          do: {binary_part(data, 0, pos), tail},
          else: {data, ""}
    end
  end

  defp find_last_esc(_data, pos, min_pos) when pos < min_pos, do: nil

  defp find_last_esc(data, pos, min_pos) do
    if :binary.at(data, pos) == 0x1B,
      do: pos,
      else: find_last_esc(data, pos - 1, min_pos)
  end

  # Lone ESC or ESC + bracket with no final byte yet
  defp incomplete_esc?(<<"\e">>), do: true

  defp incomplete_esc?(<<"\e[">>), do: true

  defp incomplete_esc?(<<"\e[", rest::binary>>) do
    # All bytes after \e[ are param/intermediate (0x20–0x3F), no final byte (0x40–0x7E)
    :binary.bin_to_list(rest) |> Enum.all?(&(&1 in 0x20..0x3F))
  end

  # OSC with no BEL or ST yet — cap at 1 KB to prevent infinite accumulation
  defp incomplete_esc?(<<"\e]", rest::binary>>) when byte_size(rest) < 1024 do
    :binary.match(rest, <<7>>) == :nomatch and
      :binary.match(rest, <<0x1B, 0x5C>>) == :nomatch
  end

  # DCS / PM / APC — all terminate with ST (\e\); cap at 1 KB
  defp incomplete_esc?(<<"\eP", rest::binary>>) when byte_size(rest) < 1024 do
    :binary.match(rest, <<0x1B, 0x5C>>) == :nomatch
  end

  defp incomplete_esc?(<<"\e^", rest::binary>>) when byte_size(rest) < 1024 do
    :binary.match(rest, <<0x1B, 0x5C>>) == :nomatch
  end

  defp incomplete_esc?(<<"\e_", rest::binary>>) when byte_size(rest) < 1024 do
    :binary.match(rest, <<0x1B, 0x5C>>) == :nomatch
  end

  defp incomplete_esc?(_), do: false

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

  # IND — index (same as LF but within scroll region)
  defp process_bytes(screen, <<"\eD", rest::binary>>),
    do: process_bytes(advance_line(screen), rest)

  # NEL — next line (CR + LF)
  defp process_bytes(screen, <<"\eE", rest::binary>>),
    do: process_bytes(advance_line(%{screen | cursor_col: 0}), rest)

  # RIS — reset to initial state (hard reset: clear screen + reset scroll region)
  defp process_bytes(screen, <<"\ec", rest::binary>>) do
    reset = %{
      screen
      | cells: %{},
        cursor_row: 0,
        cursor_col: 0,
        scroll_top: 0,
        scroll_bottom: screen.height - 1,
        style: @default_style,
        saved_cursor: {0, 0}
    }

    process_bytes(reset, rest)
  end

  # DCS (\eP), PM (\e^), APC (\e_) — string sequences terminated by ST (\e\).
  # Must be handled BEFORE the generic two-char skip or the body bytes are
  # rendered as literal text on screen (the "weird chars" artifact).
  defp process_bytes(screen, <<"\eP", rest::binary>>) do
    rest |> skip_until_osc_end() |> then(&process_bytes(screen, &1))
  end

  defp process_bytes(screen, <<"\e^", rest::binary>>) do
    rest |> skip_until_osc_end() |> then(&process_bytes(screen, &1))
  end

  defp process_bytes(screen, <<"\e_", rest::binary>>) do
    rest |> skip_until_osc_end() |> then(&process_bytes(screen, &1))
  end

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

  # VPA — vertical position absolute
  defp apply_csi(screen, params, ?d) do
    row = clamp(p(params, 0, 1) - 1, 0, screen.height - 1)
    %{screen | cursor_row: row}
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

  # ECH — erase characters
  defp apply_csi(screen, params, ?X) do
    n = p(params, 0, 1)
    erase_chars(screen, n)
  end

  # ICH — insert characters
  defp apply_csi(screen, params, ?@) do
    n = p(params, 0, 1)
    insert_chars(screen, n)
  end

  # DCH — delete characters
  defp apply_csi(screen, params, ?P) do
    n = p(params, 0, 1)
    delete_chars(screen, n)
  end

  defp apply_csi(screen, params, ?m), do: %{screen | style: apply_sgr(params, screen.style)}

  defp apply_csi(screen, _params, ?s), do: save_cursor(screen)

  defp apply_csi(screen, _params, ?u), do: restore_cursor(screen)

  # DECSTBM — set scroll region; cursor homes to (0, 0) per DEC spec (without DECOM)
  defp apply_csi(screen, params, ?r) do
    top = max(p(params, 0, 1) - 1, 0)
    bottom = min(p(params, 1, screen.height) - 1, screen.height - 1)

    if top < bottom and bottom < screen.height do
      %{screen | scroll_top: top, scroll_bottom: bottom, cursor_row: 0, cursor_col: 0}
    else
      %{screen | scroll_top: 0, scroll_bottom: screen.height - 1, cursor_row: 0, cursor_col: 0}
    end
  end

  # IL — insert N blank lines at cursor, pushing lines in scroll region down
  defp apply_csi(screen, params, ?L) do
    if in_scroll_region?(screen) do
      n = p(params, 0, 1)
      scroll_region_down(screen, screen.cursor_row, n)
    else
      screen
    end
  end

  # DL — delete N lines at cursor, pulling lines in scroll region up
  defp apply_csi(screen, params, ?M) do
    if in_scroll_region?(screen) do
      n = p(params, 0, 1)
      scroll_region_up(screen, screen.cursor_row, n)
    else
      screen
    end
  end

  # SU — scroll viewport up N lines (content moves up, cursor stays)
  defp apply_csi(screen, params, ?S) do
    n = p(params, 0, 1)
    row = screen.cursor_row
    %{scroll_up(screen, n) | cursor_row: row}
  end

  # SD — scroll viewport down N lines (content moves down, cursor stays)
  defp apply_csi(screen, params, ?T) do
    n = p(params, 0, 1)
    row = screen.cursor_row
    %{scroll_down(screen, n) | cursor_row: row}
  end

  defp apply_csi(screen, _params, _final), do: screen

  defp apply_private_csi(screen, params, ?h) do
    case List.first(params) do
      1049 -> screen
      1047 -> screen
      1048 -> save_cursor(screen)
      47 -> screen
      25 -> %{screen | cursor_visible: true}
      _ -> screen
    end
  end

  defp apply_private_csi(screen, params, ?l) do
    case List.first(params) do
      1049 -> screen
      1047 -> screen
      1048 -> restore_cursor(screen)
      47 -> screen
      25 -> %{screen | cursor_visible: false}
      _ -> screen
    end
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
    %{scroll_up(screen, 1) | cursor_row: bottom}
  end

  defp advance_line(screen) do
    %{screen | cursor_row: screen.cursor_row + 1}
  end

  defp reverse_index(%{cursor_row: row, scroll_top: top} = screen) when row <= top do
    %{scroll_down(screen, 1) | cursor_row: top}
  end

  defp reverse_index(screen) do
    %{screen | cursor_row: screen.cursor_row - 1}
  end

  defp scroll_up(screen, n) do
    top = screen.scroll_top
    bottom = screen.scroll_bottom
    n = min(n, bottom - top + 1)

    new_cells =
      if bottom - n >= top do
        Enum.reduce(top..(bottom - n)//1, screen.cells, fn row, cells ->
          Map.put(cells, row, Map.get(cells, row + n, %{}))
        end)
      else
        screen.cells
      end

    new_cells =
      Enum.reduce((bottom - n + 1)..bottom//1, new_cells, fn row, cells ->
        Map.put(cells, row, %{})
      end)

    %{screen | cells: new_cells}
  end

  defp scroll_down(screen, n) do
    top = screen.scroll_top
    bottom = screen.scroll_bottom
    n = min(n, bottom - top + 1)

    new_cells =
      Enum.reduce(bottom..top//-1, screen.cells, fn row, cells ->
        if row - n >= top do
          Map.put(cells, row, Map.get(cells, row - n, %{}))
        else
          Map.put(cells, row, %{})
        end
      end)

    %{screen | cells: new_cells}
  end

  # Scroll sub-region [start_row..scroll_bottom] up by n (IL helper — no cursor change)
  defp scroll_region_up(screen, start_row, n) do
    bottom = screen.scroll_bottom
    n = min(n, bottom - start_row + 1)

    cells =
      Enum.reduce(start_row..(bottom - n)//1, screen.cells, fn row, acc ->
        Map.put(acc, row, Map.get(acc, row + n, %{}))
      end)

    cells =
      Enum.reduce((bottom - n + 1)..bottom//1, cells, fn row, acc ->
        Map.put(acc, row, %{})
      end)

    %{screen | cells: cells}
  end

  # Scroll sub-region [start_row..scroll_bottom] down by n (IL helper — no cursor change)
  defp scroll_region_down(screen, start_row, n) do
    bottom = screen.scroll_bottom
    n = min(n, bottom - start_row + 1)

    cells =
      Enum.reduce(bottom..(start_row + n)//-1, screen.cells, fn row, acc ->
        Map.put(acc, row, Map.get(acc, row - n, %{}))
      end)

    cells =
      Enum.reduce(start_row..(start_row + n - 1)//1, cells, fn row, acc ->
        Map.put(acc, row, %{})
      end)

    %{screen | cells: cells}
  end

  defp in_scroll_region?(s),
    do: s.cursor_row >= s.scroll_top and s.cursor_row <= s.scroll_bottom

  defp insert_chars(screen, n) do
    row = screen.cursor_row
    col = screen.cursor_col
    width = screen.width
    row_cells = Map.get(screen.cells, row, %{})

    new_row =
      Enum.reduce(row_cells, %{}, fn {c, cell}, acc ->
        cond do
          c < col -> Map.put(acc, c, cell)
          c + n < width -> Map.put(acc, c + n, cell)
          true -> acc
        end
      end)

    %{screen | cells: Map.put(screen.cells, row, new_row)}
  end

  defp delete_chars(screen, n) do
    row = screen.cursor_row
    col = screen.cursor_col
    width = screen.width
    row_cells = Map.get(screen.cells, row, %{})

    new_row =
      Enum.reduce(row_cells, %{}, fn {c, cell}, acc ->
        cond do
          c < col -> Map.put(acc, c, cell)
          c < col + n -> acc
          c - n < width -> Map.put(acc, c - n, cell)
          true -> acc
        end
      end)

    %{screen | cells: Map.put(screen.cells, row, new_row)}
  end

  defp erase_chars(screen, n) do
    col = screen.cursor_col
    n = min(n, screen.width - col)

    if n > 0 do
      update_row(screen, screen.cursor_row, fn row_map ->
        Map.drop(row_map, Enum.to_list(col..(col + n - 1)//1))
      end)
    else
      screen
    end
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
    last_col = screen.width - 1
    last_row = screen.height - 1

    new_cells =
      screen.cells
      |> Map.update(row, %{}, fn row_map ->
        if screen.cursor_col <= last_col do
          Map.drop(row_map, Enum.to_list(screen.cursor_col..last_col//1))
        else
          row_map
        end
      end)
      |> then(fn cells ->
        if row + 1 <= last_row do
          Map.drop(cells, Enum.to_list((row + 1)..last_row//1))
        else
          cells
        end
      end)

    %{screen | cells: new_cells}
  end

  defp erase_above(screen) do
    row = screen.cursor_row

    new_cells =
      screen.cells
      |> Map.update(row, %{}, fn row_map ->
        Map.drop(row_map, Enum.to_list(0..screen.cursor_col//1))
      end)
      |> then(fn cells ->
        if row > 0 do
          Map.drop(cells, Enum.to_list(0..(row - 1)//1))
        else
          cells
        end
      end)

    %{screen | cells: new_cells}
  end

  defp erase_line_right(screen) do
    last_col = screen.width - 1

    if screen.cursor_col <= last_col do
      update_row(screen, screen.cursor_row, fn row_map ->
        Map.drop(row_map, Enum.to_list(screen.cursor_col..last_col//1))
      end)
    else
      screen
    end
  end

  defp erase_line_left(screen) do
    update_row(screen, screen.cursor_row, fn row_map ->
      Map.drop(row_map, Enum.to_list(0..screen.cursor_col//1))
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
  # Attribute-off codes (SGR 21–29): remove individual modifiers.
  # These are critical — Claude Code uses \e[24m to end hyperlink underlines
  # rather than a full \e[0m reset, so without these the underline bleeds
  # into all subsequent text ("weird chars" / underlined words).
  defp reduce_sgr([21 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:bold]))
  defp reduce_sgr([22 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:bold, :dim]))
  defp reduce_sgr([23 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:italic]))
  defp reduce_sgr([24 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:underlined]))

  defp reduce_sgr([25 | rest], style),
    do: reduce_sgr(rest, rem_mods(style, [:slow_blink, :rapid_blink]))

  defp reduce_sgr([27 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:reversed]))
  defp reduce_sgr([28 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:hidden]))
  defp reduce_sgr([29 | rest], style), do: reduce_sgr(rest, rem_mods(style, [:crossed_out]))
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

  # Private CSI sequences use one of < = > ? (0x3C–0x3F) as the first
  # parameter byte.  The `?` variants are the most common (DEC private modes);
  # `<` and `>` appear in the Kitty keyboard protocol and XTVERSION queries.
  # We parse them all the same way and route them to `apply_private_csi/3`.
  defp parse_csi(<<prefix::8, rest::binary>>) when prefix in [??, ?<, ?=, ?>] do
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

  # Captures param bytes (0x30–0x3F) and intermediate bytes (0x20–0x2F)
  defp split_csi(<<byte::8, rest::binary>>, acc) when byte in 0x20..0x3F do
    split_csi(rest, [byte | acc])
  end

  defp split_csi(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_csi_params(bytes) do
    bytes
    |> Enum.filter(fn b -> b in 0x30..0x3F end)
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
