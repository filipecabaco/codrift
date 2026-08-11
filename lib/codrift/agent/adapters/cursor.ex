defmodule Codrift.Agent.Adapters.Cursor do
  @moduledoc """
  Agent adapter for the Cursor CLI (`cursor-agent`).

  The executable is `cursor-agent`, not `cursor`: the latter is the editor
  launcher that opens a GUI window, so detecting it would spawn the wrong
  program. Runs in `:pty` mode — `cursor-agent` starts its interactive TUI
  when it has a terminal and falls back to one-shot print mode when it
  doesn't.

  Chat IDs are minted server-side (`cursor-agent create-chat` / `ls`), so the
  UUID Codrift generates for `--resume` would name a chat that doesn't exist;
  session persistence stays off.
  """

  @behaviour Codrift.Agent

  @executable "cursor-agent"

  def available?, do: not is_nil(System.find_executable(@executable))

  @impl true
  def cmd, do: System.find_executable(@executable) || raise("cursor-agent not found in PATH")

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
