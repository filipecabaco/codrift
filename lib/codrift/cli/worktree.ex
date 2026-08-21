defmodule Codrift.CLI.Worktree do
  @moduledoc """
  CLI for inspecting and cleaning up Codrift-managed git worktrees.

  Delegates to `Codrift.Worktree.Inventory`, reading initiatives straight from
  disk via `Codrift.CLI.Initiative.all/0`, so it works in the release `eval`
  context with no supervision tree.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift worktree list              # every managed worktree, linked and orphaned
      codrift prune                      # report what would be removed — removes nothing
      codrift prune --force              # actually remove it

  `prune` is a dry run by default. Removing a worktree can destroy uncommitted
  work in it, so nothing is deleted until `--force` says so a second time. Every
  entry carries `dirty`, and the dry run is where to notice it. Committed work is
  never at risk either way: removing a worktree leaves its branch alone.
  """

  alias Codrift.CLI.Initiative
  alias Codrift.Worktree.Inventory

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatches worktree CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["list" | _]) do
    Initiative.all()
    |> Inventory.scan()
    |> Enum.map(&Inventory.to_map/1)
    |> print_json()
  end

  def run(["prune" | rest]) do
    Initiative.all()
    |> Inventory.prune(force: "--force" in rest)
    |> Inventory.prune_to_map()
    |> print_json()
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift worktree list        Every Codrift-managed worktree and what claims it
      codrift prune                Report orphaned worktrees — removes nothing
      codrift prune --force        Remove them

    Worktrees live at ~/.codrift/initiatives/<id>/worktrees/<slug>.

    An orphan is a worktree no initiative claims any more, either because the
    initiative was deleted or because the directory was removed from it. `prune`
    also clears stale registrations — worktrees git still lists in a repository
    whose folder is gone.

    Nothing is deleted without --force: a worktree can hold uncommitted work.
    Committed work is safe regardless, since removing a worktree keeps its branch.
    """)
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))
end
