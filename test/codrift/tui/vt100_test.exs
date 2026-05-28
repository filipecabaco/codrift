defmodule Codrift.TUI.VT100Test do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.TUI.VT100

  defp cell(screen, row, col) do
    screen.cells
    |> Map.get(row, %{})
    |> Map.get(col, {" ", %ExRatatui.Style{}})
    |> elem(0)
  end

  defp row_text(screen, row) do
    0..(screen.width - 1)
    |> Enum.map_join(&cell(screen, row, &1))
    |> String.trim_trailing()
  end

  describe "basic character writing" do
    test "writes printable chars at cursor and advances" do
      s = VT100.new(20, 5) |> VT100.process("hi")
      assert cell(s, 0, 0) == "h"
      assert cell(s, 0, 1) == "i"
      assert s.cursor_col == 2
    end

    test "carriage return moves cursor to column 0" do
      s = VT100.new(20, 5) |> VT100.process("abc\rX")
      assert cell(s, 0, 0) == "X"
      assert cell(s, 0, 1) == "b"
    end

    test "linefeed advances to next row" do
      s = VT100.new(20, 5) |> VT100.process("a\nb")
      assert cell(s, 0, 0) == "a"
      assert cell(s, 1, 1) == "b"
    end

    test "backspace moves cursor left" do
      s = VT100.new(20, 5) |> VT100.process("ab\bX")
      assert cell(s, 0, 1) == "X"
    end
  end

  describe "cursor movement" do
    test "\\e[H moves to 0,0" do
      s = VT100.new(20, 5) |> VT100.process("abc\e[H")
      assert s.cursor_row == 0
      assert s.cursor_col == 0
    end

    test "\\e[row;colH positions cursor" do
      s = VT100.new(20, 10) |> VT100.process("\e[3;5H")
      assert s.cursor_row == 2
      assert s.cursor_col == 4
    end

    test "\\e[A moves cursor up" do
      s = VT100.new(20, 10) |> VT100.process("\e[5;1H\e[2A")
      assert s.cursor_row == 2
    end

    test "\\e[B moves cursor down" do
      s = VT100.new(20, 10) |> VT100.process("\e[2B")
      assert s.cursor_row == 2
    end

    test "\\e[C moves cursor right" do
      s = VT100.new(20, 5) |> VT100.process("\e[5C")
      assert s.cursor_col == 5
    end

    test "\\e[D moves cursor left" do
      s = VT100.new(20, 5) |> VT100.process("\e[5Cabc\e[2D")
      assert s.cursor_col == 6
    end

    test "save and restore cursor with ESC 7 / ESC 8" do
      s = VT100.new(20, 5) |> VT100.process("\e[3;5H\e7\e[1;1H\e8")
      assert s.cursor_row == 2
      assert s.cursor_col == 4
    end
  end

  describe "erase" do
    test "\\e[2J clears screen and homes cursor" do
      s = VT100.new(20, 5) |> VT100.process("hello\e[2J")
      assert s.cells == %{}
      assert s.cursor_row == 0
      assert s.cursor_col == 0
    end

    test "\\e[K erases to end of line (from cursor, after writing x at col 2)" do
      # \e[1;3H → col 2. Write "x" → col advances to 3. \e[K erases col 3+.
      s = VT100.new(20, 5) |> VT100.process("hello\e[1;3Hx\e[K")
      assert cell(s, 0, 0) == "h"
      assert cell(s, 0, 1) == "e"
      assert cell(s, 0, 2) == "x"
      assert cell(s, 0, 3) == " "
      assert cell(s, 0, 4) == " "
    end

    test "\\e[2K erases entire line" do
      s = VT100.new(20, 5) |> VT100.process("hello\e[1;1H\e[2K")
      assert row_text(s, 0) == ""
    end
  end

  describe "SGR colors" do
    test "\\e[32m sets green foreground" do
      s = VT100.new(20, 5) |> VT100.process("\e[32mX")
      {_, style} = Map.get(Map.get(s.cells, 0, %{}), 0, {" ", %ExRatatui.Style{}})
      assert style.fg == :green
    end

    test "\\e[0m resets style" do
      s = VT100.new(20, 5) |> VT100.process("\e[32m\e[0mX")
      {_, style} = Map.get(Map.get(s.cells, 0, %{}), 0, {" ", %ExRatatui.Style{}})
      assert style.fg == nil
    end

    test "\\e[1m sets bold modifier" do
      s = VT100.new(20, 5) |> VT100.process("\e[1mX")
      {_, style} = Map.get(Map.get(s.cells, 0, %{}), 0, {" ", %ExRatatui.Style{}})
      assert :bold in style.modifiers
    end
  end

  describe "scroll" do
    test "writing past the last row scrolls content up" do
      # Real terminals use \r\n — \n alone is linefeed (down), not carriage-return
      s =
        VT100.new(10, 3)
        |> VT100.process("row1\r\nrow2\r\nrow3\r\nrow4")

      assert row_text(s, 0) == "row2"
      assert row_text(s, 1) == "row3"
      assert row_text(s, 2) == "row4"
    end
  end

  describe "to_text/1" do
    test "produces a Text struct with one line per row" do
      s = VT100.new(10, 3)
      text = VT100.to_text(s)
      assert %ExRatatui.Text{lines: lines} = text
      assert length(lines) == 3
    end

    test "renders written characters in the correct lines (\\r\\n)" do
      s = VT100.new(20, 3) |> VT100.process("hello\r\nworld")
      text = VT100.to_text(s)
      [line0, line1 | _] = text.lines
      content0 = Enum.map_join(line0.spans, fn s -> s.content end)
      content1 = Enum.map_join(line1.spans, fn s -> s.content end)
      assert String.starts_with?(content0, "hello")
      assert String.starts_with?(content1, "world")
    end
  end

  describe "resize/3" do
    test "updating dimensions preserves existing cells" do
      s = VT100.new(20, 5) |> VT100.process("hello") |> VT100.resize(40, 10)
      assert s.width == 40
      assert s.height == 10
      assert cell(s, 0, 0) == "h"
    end
  end
end
