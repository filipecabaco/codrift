defmodule Codrift.Test.EchoAdapter do
  @moduledoc false
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("cat") || "/bin/cat"

  @impl true
  def mode, do: :interactive

  @impl true
  def args(_dir, _opts), do: []

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: []

  @impl true
  def parse_status(output) do
    if String.contains?(output, "READY"), do: :awaiting_input, else: nil
  end
end
