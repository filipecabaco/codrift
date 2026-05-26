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
  def args(dir, opts) do
    resume =
      case opts[:session_id] do
        nil ->
          # No stored UUID yet (first run). Use --continue if any previous session
          # exists in this directory so the user can pick up where they left off.
          if has_session?(dir), do: ["--continue"], else: []

        uuid ->
          # Resume the exact session we previously detected for this initiative+dir.
          ["--resume", uuid]
      end

    dir_arg =
      case opts[:context_dir] do
        nil -> []
        ctx -> ["--add-dir", ctx]
      end

    resume ++ dir_arg
  end

  # Returns true when ~/.claude/projects/<encoded-dir>/ has any .jsonl session file.
  defp has_session?(dir) do
    project_name = String.replace(dir, "/", "-")
    sessions_dir = Path.expand("~/.claude/projects/#{project_name}")

    case File.ls(sessions_dir) do
      {:ok, files} -> Enum.any?(files, &String.ends_with?(&1, ".jsonl"))
      {:error, _} -> false
    end
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
