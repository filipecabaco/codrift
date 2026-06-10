defmodule Codrift.Agent.Adapters.Claude do
  @moduledoc """
  Agent adapter for the Claude Code CLI (`claude`).

  Uses `:pty` mode so a persistent, interactive Claude Code session runs in
  the background. The PTY makes Claude think it's in a real terminal, so its
  full interactive experience (colours, streaming output, conversation history)
  works. Keypresses are forwarded directly — no per-message process spawning.
  """

  @behaviour Codrift.Agent

  @executable "claude"

  def available?, do: not is_nil(System.find_executable(@executable))

  @impl true
  def cmd, do: System.find_executable(@executable) || raise("claude CLI not found in PATH")

  @impl true
  def mode, do: :pty

  @impl true
  def args(dir, opts) do
    resume_args =
      case opts[:session_id] do
        nil ->
          []

        uuid ->
          if session_file_exists?(dir, uuid),
            do: ["--resume", uuid],
            else: ["--session-id", uuid]
      end

    dir_arg =
      case opts[:context_dir] do
        # Agent is already running inside the context dir — --add-dir would be
        # a no-op at best and an error at worst; skip it.
        nil -> []
        ^dir -> []
        ctx -> ["--add-dir", ctx]
      end

    resume_args ++ dir_arg
  end

  defp session_file_exists?(dir, uuid) do
    project_name = dir |> String.replace("/", "-") |> String.replace(".", "-")
    path = Path.expand("~/.claude/projects/#{project_name}/#{uuid}.jsonl")
    File.exists?(path)
  end

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}]

  @impl true
  def session_persistable?, do: true

  @impl true
  def tui?, do: true

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
