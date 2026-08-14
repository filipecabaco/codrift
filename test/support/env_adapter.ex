defmodule Codrift.Test.EnvAdapter do
  @moduledoc """
  Prints the environment it was spawned with and exits.

  Used to assert on what an agent actually inherits, rather than on the env
  list Codrift builds — the "unset" spelling (`{name, false}`) is interpreted by
  erlexec and by Erlang ports, so only the child can confirm it took effect.
  """
  @behaviour Codrift.Agent

  @impl true
  def cmd, do: System.find_executable("env") || "/usr/bin/env"

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
  def parse_status(_output), do: nil
end

defmodule Codrift.Test.PtyEnvAdapter do
  @moduledoc "`Codrift.Test.EnvAdapter` on the PTY spawn path (erlexec)."
  @behaviour Codrift.Agent

  @impl true
  defdelegate cmd(), to: Codrift.Test.EnvAdapter

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
