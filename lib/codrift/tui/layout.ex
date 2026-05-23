defmodule Codrift.TUI.Layout do
  @moduledoc "Rect arithmetic helpers for modal and split layout."

  alias ExRatatui.Layout.Rect

  @doc """
  Returns a `%Rect{}` centered in `frame`, sized at `percent_w`% width and
  exactly `height` rows tall. Width is clamped to [40, frame.width].
  """
  def center_rect(frame, percent_w, height) do
    w = min(max(div(frame.width * percent_w, 100), 40), frame.width)
    x = max(div(frame.width - w, 2), 0)
    y = max(div(frame.height - height, 2), 0)
    %Rect{x: x, y: y, width: w, height: min(height, frame.height)}
  end

  @doc "Shrinks `rect` by `n` cells on every side (suitable for stripping a border)."
  def inset(%Rect{x: x, y: y, width: w, height: h}, n) do
    %Rect{x: x + n, y: y + n, width: max(w - 2 * n, 0), height: max(h - 2 * n, 0)}
  end
end
