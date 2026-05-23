defmodule Codrift.TUI.Styles do
  @moduledoc "Shared style helpers for the Codrift TUI."

  alias ExRatatui.{Focus, Style}

  @doc "Returns a yellow border when `widget_id` is focused, dark gray otherwise."
  def pane_border(focus, widget_id) do
    if Focus.focused?(focus, widget_id),
      do: %Style{fg: :yellow},
      else: %Style{fg: {:indexed, 238}}
  end

  @doc "Maps an agent status atom to a display color."
  def status_color(:awaiting_input), do: :yellow
  def status_color(:running), do: :green
  def status_color(:idle), do: :cyan
  def status_color(:stopped), do: :red
  def status_color(_), do: :dark_gray
end
