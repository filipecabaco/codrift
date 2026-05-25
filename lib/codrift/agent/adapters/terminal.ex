defmodule Codrift.Agent.Adapters.Terminal do
  @moduledoc """
  Agent adapter for a plain interactive shell session.

  Uses `:pty` mode to open the user's `$SHELL` (falling back to `bash`)
  in the working directory. Keypresses are forwarded directly, giving a
  tmux-like embedded terminal experience.

  Works for any directory — not just git repos. Useful for running
  `git`, `mix`, build tools, or any CLI alongside AI agents.
  """

  @behaviour Codrift.Agent

  @impl true
  def cmd do
    System.get_env("SHELL") || System.find_executable("bash") || raise "no shell found in PATH"
  end

  @impl true
  def mode, do: :pty

  @impl true
  def args(_dir, _opts), do: []

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}]

  @impl true
  def parse_status(_output), do: nil
end
