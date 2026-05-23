defmodule Codrift.Agent.Adapters.Claude do
  @moduledoc """
  Agent adapter for the Claude Code CLI (`claude`).

  Uses `:once` mode: each user message spawns a fresh `claude --print`
  process. Subsequent messages add `--continue` so Claude picks up the
  conversation history stored in the working directory.
  """

  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("claude") || raise("claude CLI not found in PATH")

  @impl true
  def mode, do: :once

  @impl true
  def args(_dir), do: ["--print"]

  @impl true
  def args_continue(_dir), do: ["--print", "--continue"]

  @impl true
  def env(_dir), do: []

  @impl true
  def parse_status(output) do
    cond do
      String.contains?(output, "\n> ") -> :awaiting_input
      String.contains?(output, "Running") -> :running
      true -> nil
    end
  end
end
