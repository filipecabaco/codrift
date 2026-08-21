defmodule Codrift.CLI.Main do
  @moduledoc """
  Unified entry point for all codrift CLI commands.

  All release command scripts delegate here so there is one dispatch table.
  Also serves as the `main/1` entry point if the project is ever built as an
  escript.

  ## Usage

      codrift initiative <subcommand>
      codrift session    <subcommand>
      codrift memory     <subcommand>
      codrift mcp        <subcommand>
      codrift pane       <subcommand>
      codrift worktree   <subcommand>
      codrift prune
  """

  alias Codrift.CLI.Initiative
  alias Codrift.CLI.Integration
  alias Codrift.CLI.MCP
  alias Codrift.CLI.Memory
  alias Codrift.CLI.Pane
  alias Codrift.CLI.Session
  alias Codrift.CLI.Start
  alias Codrift.CLI.Update
  alias Codrift.CLI.Worktree

  @spec main([String.t()]) :: :ok
  def main(args), do: run(args)

  @spec run([String.t()]) :: :ok
  def run(["initiative" | rest]), do: Initiative.run(rest)
  def run(["integration" | rest]), do: Integration.run(rest)
  def run(["session" | rest]), do: Session.run(rest)
  def run(["memory" | rest]), do: Memory.run(rest)
  def run(["mcp" | rest]), do: MCP.run(rest)
  def run(["pane" | rest]), do: Pane.run(rest)
  def run(["update" | rest]), do: Update.run(rest)
  def run(["start" | rest]), do: Start.run(rest)
  def run(["worktree" | rest]), do: Worktree.run(rest)
  # Top-level rather than `worktree prune`: cleaning up is the verb people reach
  # for, and it is the one worktree operation worth typing without a noun.
  def run(["prune" | rest]), do: Worktree.run(["prune" | rest])

  def run(_) do
    IO.puts("""
    Usage:
      codrift start                   Launch the Codrift desktop app
      codrift initiative  <subcommand>
      codrift integration <subcommand>
      codrift session     <subcommand>
      codrift memory      <subcommand>
      codrift mcp         <subcommand>
      codrift pane        <subcommand>  Open a terminal / focus an agent for the user
      codrift worktree    <subcommand>  List Codrift-managed git worktrees
      codrift prune       [--force]     Remove worktrees no initiative claims
      codrift update

    Run `codrift <command>` with no arguments for per-command help.
    The desktop app is the primary interface — run `codrift start`.
    """)
  end
end
