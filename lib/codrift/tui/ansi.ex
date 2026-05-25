defmodule Codrift.TUI.Ansi do
  @moduledoc """
  Converts ANSI-escaped terminal output into `ExRatatui.Text` structures
  for colored rendering inside a `Paragraph` widget.

  ## What is handled

  - SGR color/style codes (`\\e[1m`, `\\e[32m`, `\\e[0m`, etc.)
  - 256-color (`\\e[38;5;Nm`) and true-color (`\\e[38;2;R;G;Bm`) foreground
  - Carriage returns and common line-ending variants

  ## What is stripped

  Cursor movement, screen erase, private mode toggles, and other control
  sequences that make no sense in a scrollable pane are removed so they
  do not appear as garbage characters.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text
  alias ExRatatui.Text.{Line, Span}

  @strip_re ~r/
    \e\[\?[\d;]*[hl]                  |
    \e\[[\d;]*[ABCDEFGHIJKSTfnsu]    |
    \e\[[\d;]*r                       |
    \e[()][0-9A-Za-z]                 |
    \e[789=>ABCDEFGHIJKLMNOPQRSTUVWYZ\\] |
    \e\][\d;]*;[^\a\e]*(?:\a|\e\\)
  /x

  @doc """
  Converts a raw terminal output binary (may contain ANSI codes) into a
  `%ExRatatui.Text{}` ready to pass as the `:text` field of a `Paragraph`.
  """
  def to_text(raw) when is_binary(raw) do
    lines =
      raw
      |> normalize()
      |> String.split("\n")
      |> Enum.map(&parse_line/1)

    %Text{lines: lines}
  end

  defp normalize(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(@strip_re, "")
  end

  defp parse_line(line) do
    parts = Regex.split(~r/\e\[[\d;]*m/, line, include_captures: true, trim: false)
    {spans, _style} = Enum.reduce(parts, {[], %Style{}}, &accumulate/2)
    %Line{spans: Enum.reverse(spans)}
  end

  defp accumulate(part, {acc, style}) do
    if String.starts_with?(part, "\e[") do
      {acc, apply_sgr(part, style)}
    else
      case part do
        "" -> {acc, style}
        _ -> {[%Span{content: part, style: style} | acc], style}
      end
    end
  end

  defp apply_sgr(seq, style) do
    codes_str = seq |> String.trim_leading("\e[") |> String.trim_trailing("m")

    codes =
      codes_str
      |> String.split(";")
      |> Enum.map(&parse_int/1)
      |> Enum.reject(&is_nil/1)

    apply_codes(codes, style)
  rescue
    _ -> style
  end

  defp apply_codes([], style), do: style
  defp apply_codes([0 | rest], _style), do: apply_codes(rest, %Style{})
  defp apply_codes([1 | rest], style), do: apply_codes(rest, add_mod(style, :bold))
  defp apply_codes([2 | rest], style), do: apply_codes(rest, add_mod(style, :dim))
  defp apply_codes([3 | rest], style), do: apply_codes(rest, add_mod(style, :italic))
  defp apply_codes([4 | rest], style), do: apply_codes(rest, add_mod(style, :underlined))
  defp apply_codes([9 | rest], style), do: apply_codes(rest, add_mod(style, :crossed_out))
  defp apply_codes([22 | rest], style), do: apply_codes(rest, rem_mod(style, [:bold, :dim]))
  defp apply_codes([39 | rest], style), do: apply_codes(rest, %{style | fg: nil})
  defp apply_codes([49 | rest], style), do: apply_codes(rest, %{style | bg: nil})
  # Standard foreground colors
  defp apply_codes([n | rest], style) when n in 30..37,
    do: apply_codes(rest, %{style | fg: ansi_color(n - 30)})

  # Bright foreground colors
  defp apply_codes([n | rest], style) when n in 90..97,
    do: apply_codes(rest, %{style | fg: bright_color(n - 90)})

  # Standard background colors
  defp apply_codes([n | rest], style) when n in 40..47,
    do: apply_codes(rest, %{style | bg: ansi_color(n - 40)})

  # Bright background colors
  defp apply_codes([n | rest], style) when n in 100..107,
    do: apply_codes(rest, %{style | bg: bright_color(n - 100)})

  # 256-color foreground: 38;5;N
  defp apply_codes([38, 5, n | rest], style),
    do: apply_codes(rest, %{style | fg: {:indexed, n}})

  # True-color foreground: 38;2;R;G;B
  defp apply_codes([38, 2, r, g, b | rest], style),
    do: apply_codes(rest, %{style | fg: {:rgb, r, g, b}})

  # 256-color background: 48;5;N
  defp apply_codes([48, 5, n | rest], style),
    do: apply_codes(rest, %{style | bg: {:indexed, n}})

  # True-color background: 48;2;R;G;B
  defp apply_codes([48, 2, r, g, b | rest], style),
    do: apply_codes(rest, %{style | bg: {:rgb, r, g, b}})

  defp apply_codes([_ | rest], style), do: apply_codes(rest, style)

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

  defp rem_mod(style, mods),
    do: %{style | modifiers: Enum.reject(style.modifiers, &(&1 in mods))}

  defp parse_int(""), do: 0
  defp parse_int(s), do: String.to_integer(s)
end
