defmodule Codrift.Agent.Adapters.Claude do
  @moduledoc """
  Agent adapter for the Claude Code CLI (`claude`).

  Uses `:pty` mode so a persistent, interactive Claude Code session runs in
  the background. The PTY makes Claude think it's in a real terminal, so its
  full interactive experience (colours, streaming output, conversation history)
  works. Keypresses are forwarded directly — no per-message process spawning.
  """

  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("claude") || raise("claude CLI not found in PATH")

  @impl true
  def mode, do: :pty

  @impl true
  def args(_dir, opts) do
    resume =
      case opts[:session_id] do
        nil -> []
        id -> ["--resume", id]
      end

    dir_arg =
      case opts[:context_dir] do
        nil -> []
        dir -> ["--add-dir", dir]
      end

    resume ++ dir_arg
  end

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}]

  @impl true
  def parse_status(output) do
    cond do
      # Claude Code's interactive prompt uses ❯ (U+276F) or > as the prompt char.
      String.contains?(output, "❯") -> :awaiting_input
      String.contains?(output, "> ") -> :awaiting_input
      String.contains?(output, "Running") -> :running
      true -> nil
    end
  end
end
