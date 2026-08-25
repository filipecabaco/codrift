defmodule Codrift.CLI.SessionWorktreeTest do
  @moduledoc """
  `codrift session` and `codrift worktree` — the two housekeeping commands.

  Both are read-mostly and both are the fallback when the desktop app is not
  running, so the case that matters is the *empty* one: a machine with no
  session database yet, or no worktrees. Neither may crash there, and both must
  still print the JSON document their caller is parsing — an agent that gets a
  stack trace where it expected `{"sessions": []}` has no way to tell "none" from
  "broken".

  `prune` is driven without `--force` on purpose: that is the reporting path,
  and the destructive one is covered against real repositories in
  `Codrift.Worktree.InventoryTest`.

  Not `async`: both read the sandboxed data and config directories.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.Session
  alias Codrift.CLI.Worktree, as: WorktreeCLI

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_data = Application.get_env(:codrift, :data_dir)
    previous_config = Application.get_env(:codrift, :config_dir)

    Application.put_env(:codrift, :data_dir, Path.join(tmp_dir, "data"))
    Application.put_env(:codrift, :config_dir, Path.join(tmp_dir, "config"))
    File.mkdir_p!(Path.join(tmp_dir, "data"))
    File.mkdir_p!(Path.join(tmp_dir, "config"))

    on_exit(fn ->
      Application.put_env(:codrift, :data_dir, previous_data)
      Application.put_env(:codrift, :config_dir, previous_config)
    end)

    :ok
  end

  defp run_json(module, argv) do
    capture_io(fn -> module.run(argv) end) |> String.trim() |> JSON.decode!()
  end

  describe "codrift session" do
    test "list on a machine with no database yet reports no sessions" do
      assert %{"sessions" => []} == run_json(Session, ["list"])
    end

    test "list scoped to an initiative is equally safe with no database" do
      assert %{"sessions" => []} == run_json(Session, ["list", "some-initiative"])
    end

    test "prune with no database prunes nothing rather than failing" do
      assert %{"pruned" => 0} == run_json(Session, ["prune"])
    end

    test "a database with no session table yields an empty list, not a stack trace" do
      # `Sqlite3.open/1` creates the file and the schema migration drops the
      # table before recreating it, so a process that dies in between leaves
      # exactly this. An agent parsing our JSON must not get a MatchError.
      File.write!(Path.join(Codrift.Paths.data_dir(), "codrift.db"), "")

      assert %{"sessions" => []} == run_json(Session, ["list"])
      assert %{"sessions" => []} == run_json(Session, ["list", "some-initiative"])
    end

    test "prune on a table-less database prunes nothing rather than crashing" do
      File.write!(Path.join(Codrift.Paths.data_dir(), "codrift.db"), "")

      assert %{"pruned" => 0} == run_json(Session, ["prune"])
    end

    test "usage names both subcommands" do
      output = capture_io(fn -> Session.run(["nonsense"]) end)

      assert output =~ "codrift session list"
      assert output =~ "codrift session prune"
    end
  end

  describe "codrift worktree" do
    test "list with no initiatives is an empty list" do
      assert [] == run_json(WorktreeCLI, ["list"])
    end

    test "prune without --force reports rather than removes" do
      result = run_json(WorktreeCLI, ["prune"])
      assert is_map(result)
    end

    test "prune accepts --force without needing anything to remove" do
      assert is_map(run_json(WorktreeCLI, ["prune", "--force"]))
    end

    test "usage explains what an orphan is and that nothing is deleted by default" do
      output = capture_io(fn -> WorktreeCLI.run(["nonsense"]) end)

      assert output =~ "codrift worktree list"
      assert output =~ "orphan"
      assert output =~ "--force"
      assert output =~ "Nothing is deleted without --force"
    end
  end
end
