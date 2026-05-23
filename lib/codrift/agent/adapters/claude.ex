defmodule Codrift.Agent.Adapters.Claude do
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("claude") || raise("claude CLI not found in PATH")

  @impl true
  def args(_dir), do: ["--no-update-check"]

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
