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
  def session_persistable?, do: false

  @impl true
  def tui?, do: false

  @impl true
  def parse_status(output) do
    if String.contains?(output, "READY"), do: :awaiting_input, else: nil
  end
end

defmodule Codrift.Test.PtyCatAdapter do
  @moduledoc """
  `cat` on the PTY spawn path.

  The terminal driver is in canonical mode, so `cat` is handed one completed
  line at a time and echoes nothing of its own (erlexec leaves `pty_echo` off).
  That makes the *shape* of what Codrift wrote observable: text with no
  terminator stays in the line buffer and produces no output at all until an
  Enter arrives.
  """
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("cat") || "/bin/cat"

  @impl true
  def mode, do: :pty

  @impl true
  def args(_dir, _opts), do: []

  @impl true
  def args_continue(_dir), do: []

  @impl true
  def env(_dir), do: []

  @impl true
  def session_persistable?, do: false

  @impl true
  def tui?, do: true

  @impl true
  def parse_status(_output), do: nil
end
