defmodule Codrift.TUI.AgentState do
  @moduledoc false
  defstruct subscribed: nil, outputs: %{}, screens: %{}, cursor_hidden_at: %{}
end
