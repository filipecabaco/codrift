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

  @doc "Returns a human-readable label for an agent status atom."
  def format_status(:awaiting_input), do: "ready"
  def format_status(:starting), do: "starting"
  def format_status(:running), do: "running"
  def format_status(:idle), do: "idle"
  def format_status(:stopped), do: "stopped"
  def format_status(other), do: to_string(other)
end
