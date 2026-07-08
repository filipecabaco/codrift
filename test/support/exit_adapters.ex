defmodule Codrift.Test.CleanExitAdapter do
  @moduledoc "Test adapter whose process exits immediately with code 0."
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("sh") || "/bin/sh"
  @impl true
  def mode, do: :interactive
  @impl true
  def args(_dir, _opts), do: ["-c", "echo done"]
  @impl true
  def args_continue(_dir), do: []
  @impl true
  def env(_dir), do: []
  @impl true
  def session_persistable?, do: false
  @impl true
  def tui?, do: false
  @impl true
  def parse_status(_output), do: nil
end

defmodule Codrift.Test.CrashExitAdapter do
  @moduledoc "Test adapter whose process exits immediately with code 3."
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("sh") || "/bin/sh"
  @impl true
  def mode, do: :interactive
  @impl true
  def args(_dir, _opts), do: ["-c", "echo boom; exit 3"]
  @impl true
  def args_continue(_dir), do: []
  @impl true
  def env(_dir), do: []
  @impl true
  def session_persistable?, do: false
  @impl true
  def tui?, do: false
  @impl true
  def parse_status(_output), do: nil
end
