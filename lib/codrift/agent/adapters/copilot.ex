defmodule Codrift.Agent.Adapters.Copilot do
  @moduledoc "Agent adapter for GitHub Copilot CLI (`gh copilot suggest`)."

  @behaviour Codrift.Agent

  @executable "gh"

  def available?, do: not is_nil(System.find_executable(@executable))

  @impl true
  def cmd, do: System.find_executable(@executable) || raise("gh not found in PATH")

  @impl true
  def mode, do: :interactive

  @impl true
  def args(_dir, _opts), do: ["copilot", "suggest"]

  @impl true
  def args_continue(_dir), do: ["copilot", "suggest"]

  @impl true
  def env(_dir), do: []

  @impl true
  def session_persistable?, do: false

  @impl true
  def tui?, do: false

  @impl true
  def parse_status(output) do
    cond do
      String.contains?(output, "\e[2J") -> :awaiting_input
      String.contains?(output, "? ") -> :awaiting_input
      true -> nil
    end
  end
end
