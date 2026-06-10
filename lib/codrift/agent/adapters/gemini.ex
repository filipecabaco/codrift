defmodule Codrift.Agent.Adapters.Gemini do
  @moduledoc "Agent adapter for Google Gemini CLI (`gemini`)."

  @behaviour Codrift.Agent

  @executable "gemini"

  def available?, do: not is_nil(System.find_executable(@executable))

  @impl true
  def cmd, do: System.find_executable(@executable) || raise("gemini not found in PATH")

  @impl true
  def mode, do: :pty

  @impl true
  def args(_dir, _opts), do: []

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}]

  @impl true
  def session_persistable?, do: false

  @impl true
  def tui?, do: true

  @impl true
  def parse_status(output) do
    cond do
      String.contains?(output, "\e[2J") -> :awaiting_input
      String.contains?(output, "> ") -> :awaiting_input
      true -> nil
    end
  end
end
