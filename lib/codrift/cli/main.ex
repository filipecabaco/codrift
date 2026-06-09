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
      codrift tui
      codrift mcp        <subcommand>
  """

  alias Codrift.CLI.Initiative
  alias Codrift.CLI.Integration
  alias Codrift.CLI.MCP
  alias Codrift.CLI.Memory
  alias Codrift.CLI.Session
  alias Codrift.CLI.TUI
  alias Codrift.CLI.Update

  @spec main([String.t()]) :: :ok
  def main(args), do: run(args)

  @spec run([String.t()]) :: :ok
  def run(["initiative" | rest]), do: Initiative.run(rest)
  def run(["integration" | rest]), do: Integration.run(rest)
  def run(["session" | rest]), do: Session.run(rest)
  def run(["memory" | rest]), do: Memory.run(rest)
  def run(["tui" | rest]), do: TUI.run(rest)
  def run(["mcp" | rest]), do: MCP.run(rest)
  def run(["update" | rest]), do: Update.run(rest)

  # Positional file/dir arguments: open as a temporary initiative in the TUI.
  def run(paths) when paths != [], do: TUI.run(paths)

  def run(_) do
    IO.puts("""
    Usage:
      codrift initiative  <subcommand>
      codrift integration <subcommand>
      codrift session     <subcommand>
      codrift memory      <subcommand>
      codrift tui
      codrift mcp         <subcommand>
      codrift update

    Run `codrift <command>` with no arguments for per-command help.
    """)
  end
end
