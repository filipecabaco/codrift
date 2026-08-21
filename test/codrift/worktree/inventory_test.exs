defmodule Codrift.Worktree.InventoryTest do
  @moduledoc false
  # Redirects Codrift.Paths at the application env, which is global.
  use ExUnit.Case, async: false

  alias Codrift.Initiative
  alias Codrift.Initiative.DirEntry
  alias Codrift.Test.GitRepo
  alias Codrift.Worktree
  alias Codrift.Worktree.Inventory

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    data = Path.join(tmp_dir, "codrift")
    File.mkdir_p!(Path.join(data, "initiatives"))
    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, data)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codrift, :data_dir, previous),
        else: Application.delete_env(:codrift, :data_dir)
    end)

    {:ok, data: data}
  end

  # Builds an initiative with a real repo and a real worktree on disk, exactly as
  # Store.add_dir(worktree_enabled: true) would.
  defp initiative_with_worktree(tmp_dir, name) do
    initiative = Initiative.new(name)
    repo = GitRepo.init_with!(Path.join(tmp_dir, "repo-#{name}"), %{"README.md" => "hi"})
    ctx = Codrift.Paths.initiative_dir(initiative.id)
    File.mkdir_p!(ctx)

    {:ok, wt} = Worktree.ensure(ctx, initiative.id, repo)
    entry = %DirEntry{path: repo, worktree_enabled: true, worktree_path: wt}

    {%{initiative | dirs: [entry]}, repo, wt}
  end

  describe "scan/1" do
    test "finds a worktree and calls it linked while its initiative claims it", %{
      tmp_dir: tmp_dir
    } do
      {initiative, repo, wt} = initiative_with_worktree(tmp_dir, "alpha")

      assert [entry] = Inventory.scan([initiative])
      assert entry.path == wt
      assert entry.initiative_id == initiative.id
      assert entry.initiative_name == "alpha"
      assert entry.state == :linked
      assert entry.reason == nil
      assert entry.source_path == repo
      assert entry.branch == Worktree.branch_name(initiative.id, repo)
      refute entry.dirty?
    end

    test "an initiative that no longer exists leaves an orphan", %{tmp_dir: tmp_dir} do
      {_initiative, _repo, wt} = initiative_with_worktree(tmp_dir, "beta")

      assert [entry] = Inventory.scan([])
      assert entry.path == wt
      assert entry.state == :orphan
      assert entry.reason == :initiative_deleted
      # The source repo is still nameable, which is what lets prune use
      # `git worktree remove` rather than a blind delete.
      assert entry.source_path =~ "repo-beta"
    end

    test "an initiative that dropped the directory leaves an orphan", %{tmp_dir: tmp_dir} do
      {initiative, _repo, _wt} = initiative_with_worktree(tmp_dir, "gamma")
      forgetful = %{initiative | dirs: []}

      assert [entry] = Inventory.scan([forgetful])
      assert entry.state == :orphan
      assert entry.reason == :not_referenced
      # Still attributed to its initiative — an orphan you cannot trace is one
      # nobody dares delete.
      assert entry.initiative_name == "gamma"
    end

    test "reports uncommitted work, which is what makes a delete dangerous", %{tmp_dir: tmp_dir} do
      {initiative, _repo, wt} = initiative_with_worktree(tmp_dir, "delta")
      File.write!(Path.join(wt, "scratch.txt"), "unsaved")

      assert [%{dirty?: true}] = Inventory.scan([initiative])
    end

    test "is empty when nothing has ever made a worktree" do
      assert Inventory.scan([]) == []
    end
  end

  describe "prune/2" do
    test "reports without deleting anything by default", %{tmp_dir: tmp_dir} do
      {_initiative, _repo, wt} = initiative_with_worktree(tmp_dir, "epsilon")

      result = Inventory.prune([])

      assert result.dry_run
      assert [%{path: ^wt}] = result.orphans
      assert result.removed == []
      assert File.dir?(wt), "dry run must not touch the filesystem"
    end

    test "removes orphans under force", %{tmp_dir: tmp_dir} do
      {_initiative, _repo, wt} = initiative_with_worktree(tmp_dir, "zeta")

      result = Inventory.prune([], force: true)

      refute result.dry_run
      assert [%{path: ^wt}] = result.removed
      assert result.failed == []
      refute File.exists?(wt)
    end

    test "leaves linked worktrees alone even under force", %{tmp_dir: tmp_dir} do
      {initiative, _repo, wt} = initiative_with_worktree(tmp_dir, "eta")

      result = Inventory.prune([initiative], force: true)

      assert result.orphans == []
      assert result.removed == []
      assert File.dir?(wt)
    end

    # The one guarantee that makes forcing tolerable.
    test "keeps the branch, so committed work survives removal", %{tmp_dir: tmp_dir} do
      {_initiative, repo, wt} = initiative_with_worktree(tmp_dir, "theta")
      File.write!(Path.join(wt, "work.txt"), "committed work")
      GitRepo.commit!(wt, "keep me")
      branch = Worktree.status(wt).branch

      Inventory.prune([], force: true)

      {out, 0} = GitRepo.git(repo, ["branch", "--list", branch])
      assert String.trim(out) != "", "removing a worktree must not delete its branch"
      {log, 0} = GitRepo.git(repo, ["log", "--oneline", branch])
      assert log =~ "keep me"
    end

    test "counts dirty orphans so a dry run can warn before forcing", %{tmp_dir: tmp_dir} do
      {_i1, _r1, wt} = initiative_with_worktree(tmp_dir, "iota")
      {_i2, _r2, _clean} = initiative_with_worktree(tmp_dir, "kappa")
      File.write!(Path.join(wt, "scratch.txt"), "unsaved")

      result = Inventory.prune([])

      assert %{orphans: [_, _], dirty_count: 1} = result
    end
  end

  describe "stale_registrations/1" do
    test "finds a worktree the repo still lists after its folder is gone", %{tmp_dir: tmp_dir} do
      {initiative, repo, wt} = initiative_with_worktree(tmp_dir, "lambda")
      # Deleting the folder behind git's back is exactly how these appear — the
      # test suite has leaked them into real repositories this way.
      File.rm_rf!(wt)

      assert [%{repo: ^repo, path: ^wt}] = Inventory.stale_registrations([initiative])
    end

    test "a healthy repository reports none", %{tmp_dir: tmp_dir} do
      {initiative, _repo, _wt} = initiative_with_worktree(tmp_dir, "mu")

      assert Inventory.stale_registrations([initiative]) == []
    end

    test "force clears them from git's registry", %{tmp_dir: tmp_dir} do
      {initiative, repo, wt} = initiative_with_worktree(tmp_dir, "nu")
      File.rm_rf!(wt)
      assert [_] = Inventory.stale_registrations([initiative])

      Inventory.prune([initiative], force: true)

      assert Inventory.stale_registrations([initiative]) == []
      {out, 0} = GitRepo.git(repo, ["worktree", "list"])
      refute out =~ "prunable"
    end

    test "a directory that is not a git repository is skipped, not crashed on", %{
      tmp_dir: tmp_dir
    } do
      plain = Path.join(tmp_dir, "not-a-repo")
      File.mkdir_p!(plain)

      initiative = %{Initiative.new("plain") | dirs: [%DirEntry{path: plain}]}

      assert Inventory.stale_registrations([initiative]) == []
    end
  end
end
