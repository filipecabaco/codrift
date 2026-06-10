defmodule Codrift.Agent.Adapters.Opencode do
  @moduledoc "Agent adapter for Opencode (`opencode`)."

  @behaviour Codrift.Agent

  @executable "opencode"

  def available?, do: not is_nil(System.find_executable(@executable))

  @impl true
  def cmd, do: System.find_executable(@executable) || raise("opencode not found in PATH")

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
    # Bubble Tea emits \e[2J when it draws its first full frame — that's the
    # signal that the TUI is up and awaiting input.
    if String.contains?(output, "\e[2J"), do: :awaiting_input
  end
end
