defmodule Codrift.TUI.Styles do
  @moduledoc "Shared style helpers for the Codrift TUI."

  alias Codrift.Config.Theme
  alias ExRatatui.{Focus, Style}

  @doc """
  Returns a border style for a pane: the theme's `border_focused` colour when
  `widget_id` is focused, `border_unfocused` otherwise.

  Accepts an optional `%Theme{}` struct; when omitted the default theme is used.
  """
  @spec pane_border(Focus.t(), atom(), Theme.t() | nil) :: Style.t()
  def pane_border(focus, widget_id, theme \\ nil) do
    t = theme || Theme.default()

    if Focus.focused?(focus, widget_id),
      do: %Style{fg: t.border_focused},
      else: %Style{fg: t.border_unfocused}
  end

  @doc """
  Returns the border style used for the diff content pane (always "active" —
  the diff pane is the primary reading surface in diff mode).
  """
  @spec diff_border(Theme.t() | nil) :: Style.t()
  def diff_border(theme \\ nil) do
    t = theme || Theme.default()
    %Style{fg: t.diff_border}
  end

  @doc """
  Returns the sidebar list highlight style (selected row).
  """
  @spec sidebar_highlight(Theme.t() | nil) :: Style.t()
  def sidebar_highlight(theme \\ nil) do
    t = theme || Theme.default()
    %Style{fg: :black, bg: t.sidebar_highlight, modifiers: [:bold]}
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
