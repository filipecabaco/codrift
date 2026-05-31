defmodule Codrift.TUI.SidebarTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Agent.Adapters.Claude
  alias Codrift.Diff.FileDiff
  alias Codrift.Initiative
  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.TUI.Sidebar

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp initiative(overrides \\ []) do
    struct!(
      Initiative,
      Keyword.merge(
        [
          id: "init-1",
          name: "Test Project",
          dirs: [],
          created_at: DateTime.utc_now(),
          status: :ongoing
        ],
        overrides
      )
    )
  end

  defp agent(overrides \\ []) do
    Map.merge(
      %{
        id: "agent-1",
        initiative_id: "init-1",
        dir: "/repo",
        adapter: Claude,
        status: :running,
        mode: :pty
      },
      Map.new(overrides)
    )
  end

  defp file_diff(overrides \\ []) do
    struct!(
      FileDiff,
      Keyword.merge(
        [path: "lib/foo.ex", old_path: "lib/foo.ex", hunks: [], additions: 5, deletions: 2],
        overrides
      )
    )
  end

  defp init_git_repo(path) do
    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "Test"], cd: path, stderr_to_stdout: true)

    System.cmd("git", ["commit", "--allow-empty", "-m", "initial"],
      cd: path,
      stderr_to_stdout: true
    )
  end

  # ---------------------------------------------------------------------------
  # build_entries/2
  # ---------------------------------------------------------------------------

  describe "build_entries/2" do
    test "empty list when there are no initiatives" do
      assert [] = Sidebar.build_entries([], [])
    end

    test "initiative with no dirs produces header + context_dir only" do
      init = initiative(id: "abc", name: "My App", dirs: [])
      entries = Sidebar.build_entries([init], [])

      assert [
               {:initiative, "abc", "My App", 0, 0, :ongoing},
               {:context_dir, "abc", _ctx_path, 0}
             ] = entries
    end

    test "initiative with dirs includes dir entries after the context_dir" do
      init =
        initiative(id: "abc", dirs: [DirEntry.new("/repo/a"), DirEntry.new("/repo/b")])

      entries = Sidebar.build_entries([init], [])

      assert [{:initiative, "abc", _, 2, 0, _} | rest] = entries

      types = Enum.map(rest, &elem(&1, 0))
      assert :context_dir in types
      assert :dir in types
    end

    test "agent nested under its directory entry when the dir matches an initiative dir" do
      init = initiative(id: "abc", dirs: [DirEntry.new("/repo")])
      ag = agent(initiative_id: "abc", dir: "/repo")
      entries = Sidebar.build_entries([init], [ag])

      # Initiative header shows 1 agent
      assert {:initiative, "abc", _, _, 1, _} = hd(entries)

      agent_entries = Enum.filter(entries, &(elem(&1, 0) == :agent))
      assert [{:agent, "agent-1", _, :running}] = agent_entries
    end

    test "multiple initiatives each produce their own header" do
      inits = [
        initiative(id: "a", name: "Alpha", dirs: []),
        initiative(id: "b", name: "Beta", dirs: [])
      ]

      entries = Sidebar.build_entries(inits, [])

      initiative_entries = Enum.filter(entries, &(elem(&1, 0) == :initiative))
      names = Enum.map(initiative_entries, &elem(&1, 2))
      assert "Alpha" in names
      assert "Beta" in names
    end

    test "agent count on the initiative header reflects the number of running agents" do
      init = initiative(id: "abc", dirs: [DirEntry.new("/repo")])

      agents = [
        agent(id: "a1", initiative_id: "abc", dir: "/repo"),
        agent(id: "a2", initiative_id: "abc", dir: "/repo")
      ]

      entries = Sidebar.build_entries([init], agents)

      assert {:initiative, "abc", _, _, 2, _} = hd(entries)
    end

    test "agents from different initiatives do not bleed across headers" do
      init_a = initiative(id: "a", name: "Alpha", dirs: [DirEntry.new("/repo")])
      init_b = initiative(id: "b", name: "Beta", dirs: [DirEntry.new("/other")])

      agents = [
        agent(id: "ag1", initiative_id: "a", dir: "/repo"),
        agent(id: "ag2", initiative_id: "b", dir: "/other")
      ]

      entries = Sidebar.build_entries([init_a, init_b], agents)

      {_, alpha_count} =
        Enum.find_value(entries, fn
          {:initiative, "a", _, _, count, _} -> {true, count}
          _ -> nil
        end)

      {_, beta_count} =
        Enum.find_value(entries, fn
          {:initiative, "b", _, _, count, _} -> {true, count}
          _ -> nil
        end)

      assert alpha_count == 1
      assert beta_count == 1
    end

    test "initiative status :planning is preserved" do
      init = initiative(id: "abc", status: :planning)
      [{:initiative, _, _, _, _, status} | _] = Sidebar.build_entries([init], [])
      assert status == :planning
    end

    test "nil status defaults to :ongoing" do
      init = initiative(id: "abc", status: nil)
      [{:initiative, _, _, _, _, status} | _] = Sidebar.build_entries([init], [])
      assert status == :ongoing
    end

    test "initiative with no dirs still has a dir_count of 0 in the header" do
      init = initiative(id: "abc", dirs: [])
      [{:initiative, _, _, dir_count, _, _} | _] = Sidebar.build_entries([init], [])
      assert dir_count == 0
    end

    test "dir entry without worktree has nil wt_status" do
      init = initiative(id: "abc", dirs: [DirEntry.new("/repo")])
      entries = Sidebar.build_entries([init], [])
      [{:dir, "abc", "/repo", wt_status, _count}] = for e = {:dir, _, _, _, _} <- entries, do: e
      assert is_nil(wt_status)
    end

    @tag :tmp_dir
    test "dir entry with active worktree has non-nil wt_status", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)
      {:ok, wt_path} = Codrift.Worktree.ensure(ctx, "wt-sidebar", repo)

      entry = DirEntry.new(repo, worktree_enabled: true, worktree_path: wt_path)
      init = initiative(id: "abc", dirs: [entry])
      entries = Sidebar.build_entries([init], [])

      [{:dir, "abc", ^repo, wt_status, _count}] = for e = {:dir, _, _, _, _} <- entries, do: e
      assert %{branch: branch, dirty?: false} = wt_status
      assert is_binary(branch)
    end

    test "subdirectories in context folder are excluded from context file entries" do
      id = "test-sidebar-subdir-#{System.unique_integer([:positive])}"
      ctx = Store.context_path(id)
      File.mkdir_p!(ctx)
      on_exit(fn -> File.rm_rf!(ctx) end)

      File.write!(Path.join(ctx, "notes.md"), "some notes")
      File.mkdir_p!(Path.join(ctx, "worktrees"))
      File.mkdir_p!(Path.join(ctx, "subdir"))

      init = initiative(id: id, dirs: [])
      entries = Sidebar.build_entries([init], [])

      context_files = for {:context_file, _, _, name} <- entries, do: name
      assert "notes.md" in context_files
      refute "worktrees" in context_files
      refute "subdir" in context_files
    end

    test "dotfiles in context folder are excluded from context file entries" do
      id = "test-sidebar-dotfiles-#{System.unique_integer([:positive])}"
      ctx = Store.context_path(id)
      File.mkdir_p!(ctx)
      on_exit(fn -> File.rm_rf!(ctx) end)

      File.write!(Path.join(ctx, "visible.md"), "content")
      File.write!(Path.join(ctx, ".hidden"), "hidden")

      init = initiative(id: id, dirs: [])
      entries = Sidebar.build_entries([init], [])

      context_files = for {:context_file, _, _, name} <- entries, do: name
      assert "visible.md" in context_files
      refute ".hidden" in context_files
    end
  end

  # ---------------------------------------------------------------------------
  # build_diff_entries/1
  # ---------------------------------------------------------------------------

  describe "build_diff_entries/1" do
    test "completely empty input returns a single :diff_all entry with zero counts" do
      assert [{:diff_all, 0, 0}] = Sidebar.build_diff_entries([])
    end

    test "dir with no changed files returns :diff_all with zero counts" do
      assert [{:diff_all, 0, 0}] = Sidebar.build_diff_entries([{"/repo", []}])
    end

    test "single changed file produces all / dir / file entries in order" do
      f = file_diff(path: "lib/app.ex", additions: 3, deletions: 1)
      entries = Sidebar.build_diff_entries([{"/repo", [f]}])

      assert [
               {:diff_all, 3, 1},
               {:diff_dir, "/repo", 3, 1},
               {:diff_file, "/repo", "lib/app.ex", 3, 1}
             ] = entries
    end

    test "totals in :diff_all aggregate across multiple dirs" do
      f1 = file_diff(path: "a.ex", additions: 10, deletions: 2)
      f2 = file_diff(path: "b.ex", additions: 5, deletions: 0)
      [{:diff_all, adds, dels} | _] = Sidebar.build_diff_entries([{"/a", [f1]}, {"/b", [f2]}])

      assert adds == 15
      assert dels == 2
    end

    test "dirs with no changes are excluded from entries" do
      f = file_diff(path: "x.ex", additions: 1, deletions: 0)
      entries = Sidebar.build_diff_entries([{"/has-changes", [f]}, {"/empty", []}])

      dirs = entries |> Enum.filter(&(elem(&1, 0) == :diff_dir)) |> Enum.map(&elem(&1, 1))
      assert "/has-changes" in dirs
      refute "/empty" in dirs
    end

    test "multiple files per dir each get a :diff_file entry" do
      f1 = file_diff(path: "a.ex", additions: 1, deletions: 0)
      f2 = file_diff(path: "b.ex", additions: 2, deletions: 1)
      entries = Sidebar.build_diff_entries([{"/repo", [f1, f2]}])

      file_entries = Enum.filter(entries, &(elem(&1, 0) == :diff_file))
      assert length(file_entries) == 2
    end

    test "per-dir addition/deletion counts sum all files in that dir" do
      f1 = file_diff(path: "a.ex", additions: 4, deletions: 1)
      f2 = file_diff(path: "b.ex", additions: 2, deletions: 3)
      entries = Sidebar.build_diff_entries([{"/repo", [f1, f2]}])

      assert {:diff_dir, "/repo", 6, 4} = Enum.find(entries, &(elem(&1, 0) == :diff_dir))
    end
  end
end
