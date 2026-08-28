defmodule Codrift.CLI.Main do
  @moduledoc """
  Unified entry point for all codrift CLI commands.

  All release command scripts delegate here so there is one dispatch table.
  Also serves as the `main/1` entry point if the project is ever built as an
  escript.

  Every command comes through `run/1`, which is also where the standard-io
  encoding is forced to `:unicode` — see `force_unicode_io/0`.

  ## Usage

      codrift initiative <subcommand>
      codrift session    <subcommand>
      codrift memory     <subcommand>
      codrift mcp        <subcommand>
      codrift pane       <subcommand>
      codrift open       <initiative_id> <path>
      codrift worktree   <subcommand>
      codrift prune
  """

  alias Codrift.CLI.Initiative
  alias Codrift.CLI.Integration
  alias Codrift.CLI.MCP
  alias Codrift.CLI.Memory
  alias Codrift.CLI.Open
  alias Codrift.CLI.Pane
  alias Codrift.CLI.Session
  alias Codrift.CLI.Start
  alias Codrift.CLI.Update
  alias Codrift.CLI.Worktree

  @spec main([String.t()]) :: :ok
  def main(args), do: run(args)

  @spec run([String.t()]) :: :ok
  def run(args) do
    force_unicode_io()
    dispatch(args)
  end

  # The BEAM takes its standard-io encoding from the caller's locale. With LANG
  # and LC_ALL unset it settles on latin1, and writing a UTF-8 binary to a
  # latin1 device mangles every non-ASCII codepoint in two different ways:
  # above U+00FF into Erlang's literal `\x{2014}` notation, which is not a
  # legal JSON escape and so breaks every agent parsing `codrift memory ...`;
  # and U+0080..U+00FF into a raw latin1 byte, which is not valid UTF-8 at all
  # (an accented name in a memory entry is enough). Both the JSON path and the
  # human-readable one go through this device, and so does `fail/1` on stderr.
  #
  # Forcing the encoding here makes correct output the default rather than
  # something the caller has to arrange a locale for, and it covers every
  # command because every command is dispatched from `run/1`. Setting the
  # locale in the Burrito launcher would fix only that one channel; writing
  # bytes from `print_json/1` would fix only the JSON half.
  #
  # `:standard_io` resolves to the calling process's group leader, which under
  # `ExUnit.CaptureIO` is a StringIO that may refuse `setopts` — the return is
  # discarded so a test never fails on it.
  defp force_unicode_io do
    _ = :io.setopts(:standard_io, encoding: :unicode)
    _ = :io.setopts(:standard_error, encoding: :unicode)
    :ok
  end

  defp dispatch(["initiative" | rest]), do: Initiative.run(rest)
  defp dispatch(["integration" | rest]), do: Integration.run(rest)
  defp dispatch(["session" | rest]), do: Session.run(rest)
  defp dispatch(["memory" | rest]), do: Memory.run(rest)
  defp dispatch(["mcp" | rest]), do: MCP.run(rest)
  defp dispatch(["pane" | rest]), do: Pane.run(rest)
  # Top-level rather than `pane open`: it is the one handoff that names a thing
  # the user already has a word for, and `codrift open <file>` is what someone
  # reaches for without reading the help.
  defp dispatch(["open" | rest]), do: Open.run(rest)
  defp dispatch(["update" | rest]), do: Update.run(rest)
  defp dispatch(["start" | rest]), do: Start.run(rest)
  defp dispatch(["worktree" | rest]), do: Worktree.run(rest)
  # Top-level rather than `worktree prune`: cleaning up is the verb people reach
  # for, and it is the one worktree operation worth typing without a noun.
  defp dispatch(["prune" | rest]), do: Worktree.run(["prune" | rest])

  defp dispatch(_) do
    IO.puts("""
    Usage:
      codrift start                   Launch the Codrift desktop app
      codrift initiative  <subcommand>
      codrift integration <subcommand>
      codrift session     <subcommand>
      codrift memory      <subcommand>
      codrift mcp         <subcommand>
      codrift open        <initiative_id> <path>
                                        Open a file and keep it in the initiative
      codrift pane        <subcommand>  Open a terminal / focus an agent for the user
      codrift worktree    <subcommand>  List Codrift-managed git worktrees
      codrift prune       [--force]     Remove worktrees no initiative claims
      codrift update

    Run `codrift <command>` with no arguments for per-command help.
    The desktop app is the primary interface — run `codrift start`.
    """)
  end
end
