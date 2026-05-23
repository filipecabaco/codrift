defmodule Codrift.Agent.Adapters.Aider do
  @moduledoc "Agent adapter for the Aider CLI (`aider`)."

  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("aider") || raise("aider not found in PATH")

  @impl true
  def args(_dir), do: ["--no-auto-commits"]

  @impl true
  def env(_dir), do: []

  @impl true
  def parse_status(output) do
    cond do
      String.contains?(output, "aider>") -> :awaiting_input
      String.contains?(output, "Tokens:") -> :idle
      true -> nil
    end
  end
end
