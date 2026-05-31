defmodule Codrift.WorktreeTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Worktree

  @moduletag :tmp_dir

  defp init_git_repo(path) do
    System.cmd("git", ["init"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: path, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.name", "Test"], cd: path, stderr_to_stdout: true)

    System.cmd("git", ["commit", "--allow-empty", "-m", "initial"],
      cd: path,
      stderr_to_stdout: true
    )
  end

  describe "git_repo?/1" do
    test "returns true for a git repository", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
      assert Worktree.git_repo?(repo)
    end

    test "returns false for a plain directory", %{tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)
      refute Worktree.git_repo?(plain)
    end

    test "returns false for a non-existent path" do
      refute Worktree.git_repo?("/this/does/not/exist")
    end
  end

  describe "worktree_path/2" do
    test "places worktree inside the context path", %{tmp_dir: tmp_dir} do
      wt = Worktree.worktree_path(tmp_dir, "/home/user/myrepo")
      assert String.starts_with?(wt, Path.join(tmp_dir, "worktrees/"))
    end

    test "two different source paths produce different worktree paths", %{tmp_dir: tmp_dir} do
      wt1 = Worktree.worktree_path(tmp_dir, "/home/user/repo-a")
      wt2 = Worktree.worktree_path(tmp_dir, "/home/user/repo-b")
      assert wt1 != wt2
    end
  end

  describe "branch_name/2" do
    test "includes the initiative id prefix and a slug" do
      branch = Worktree.branch_name("abc12345def67890", "/home/user/myrepo")
      assert String.starts_with?(branch, "codrift/abc12345/")
    end

    test "two different source paths produce different branch names" do
      b1 = Worktree.branch_name("abc12345", "/home/user/repo-a")
      b2 = Worktree.branch_name("abc12345", "/home/user/repo-b")
      assert b1 != b2
    end
  end

  describe "ensure/3" do
    test "creates a worktree and returns {:ok, path}", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)

      assert {:ok, wt_path} = Worktree.ensure(ctx, "init-id", repo)
      assert File.dir?(wt_path)
      assert String.starts_with?(wt_path, Path.join(ctx, "worktrees/"))
    end

    test "is idempotent — returns the same path on repeated calls", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)

      assert {:ok, wt1} = Worktree.ensure(ctx, "init-id", repo)
      assert {:ok, wt2} = Worktree.ensure(ctx, "init-id", repo)
      assert wt1 == wt2
    end

    test "returns {:error, reason} for a non-git directory", %{tmp_dir: tmp_dir} do
      not_git = Path.join(tmp_dir, "not-git")
      File.mkdir_p!(not_git)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)

      assert {:error, _reason} = Worktree.ensure(ctx, "some-id", not_git)
    end
  end

  describe "remove/2" do
    test "removes the worktree directory", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)

      {:ok, wt_path} = Worktree.ensure(ctx, "rm-test", repo)
      assert File.dir?(wt_path)

      assert :ok = Worktree.remove(repo, wt_path)
      refute File.dir?(wt_path)
    end

    test "returns :ok even when worktree path does not exist", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      assert :ok = Worktree.remove(repo, Path.join(tmp_dir, "nonexistent"))
    end
  end

  describe "status/1" do
    test "returns branch name and clean status for a fresh worktree", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)
      {:ok, wt_path} = Worktree.ensure(ctx, "status-test", repo)

      assert %{branch: branch, dirty?: false} = Worktree.status(wt_path)
      assert is_binary(branch) and branch != ""
    end

    test "returns dirty?: true when the worktree has uncommitted changes", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      ctx = Path.join(tmp_dir, "ctx")
      File.mkdir_p!(ctx)
      {:ok, wt_path} = Worktree.ensure(ctx, "dirty-test", repo)

      File.write!(Path.join(wt_path, "new_file.txt"), "uncommitted")

      assert %{dirty?: true} = Worktree.status(wt_path)
    end

    test "returns a map with branch and dirty? keys for any path", %{tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)
      result = Worktree.status(plain)
      assert is_binary(result.branch)
      assert is_boolean(result.dirty?)
    end
  end
end
