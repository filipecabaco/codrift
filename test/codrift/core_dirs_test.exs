defmodule Codrift.CoreDirsTest do
  @moduledoc """
  Coverage for the three operations behind "add a directory and look at it":
  `inspect_dir` (what kind of thing is this?), `add_dir` (with or without git
  isolation), and `dir_preview` (what is inside it?).

  The interesting contract is that `dir_preview` reads through a directory's
  *effective* path: for a worktree-backed entry the preview must describe the
  worktree, not the source repo, because that is where agents actually work.

  Not `async`: `Core.call/2` goes through the globally-named store.
  """
  use ExUnit.Case, async: false

  alias Codrift.Core
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  setup do
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "core-dirs-test"})
    id = initiative["id"]
    on_exit(fn -> Core.call("delete_initiative", %{"initiative_id" => id}) end)
    {:ok, initiative_id: id}
  end

  describe "inspect_dir" do
    test "a repo root can take a worktree", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)

      assert {:ok, %{"git_root" => true, "git" => true, "exists" => true, "dir" => true}} =
               Core.call("inspect_dir", %{"path" => repo})
    end

    test "a plain folder cannot", %{tmp_dir: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(plain)

      assert {:ok, %{"git_root" => false}} = Core.call("inspect_dir", %{"path" => plain})
    end
  end

  describe "add_dir" do
    test "adds a plain directory without a worktree", %{initiative_id: id, tmp_dir: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(plain)

      assert {:ok, %{"dirs" => dirs}} =
               Core.call("add_dir", %{"initiative_id" => id, "dir" => plain})

      assert [%{"path" => ^plain, "worktree_enabled" => false}] = dirs
    end

    test "opts into a worktree when asked", %{initiative_id: id, tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)

      assert {:ok, %{"dirs" => [dir]}} =
               Core.call("add_dir", %{
                 "initiative_id" => id,
                 "dir" => repo,
                 "worktree" => true
               })

      assert dir["worktree_enabled"]
      assert File.dir?(dir["worktree_path"])
      # The worktree is a separate checkout, not the source repo itself.
      refute dir["worktree_path"] == repo
    end

    test "accepts the flag as a string, the way a loose client sends it",
         %{initiative_id: id, tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)

      assert {:ok, %{"dirs" => [dir]}} =
               Core.call("add_dir", %{
                 "initiative_id" => id,
                 "dir" => repo,
                 "worktree" => "true"
               })

      assert dir["worktree_enabled"]
    end

    test "ignores the worktree flag for a directory that is not a repo",
         %{initiative_id: id, tmp_dir: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(plain)

      assert {:ok, %{"dirs" => [dir]}} =
               Core.call("add_dir", %{
                 "initiative_id" => id,
                 "dir" => plain,
                 "worktree" => true
               })

      refute dir["worktree_enabled"]
    end
  end

  describe "dir_preview" do
    test "returns the directory's README", %{initiative_id: id, tmp_dir: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(plain)
      File.write!(Path.join(plain, "README.md"), "# Project")
      {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => plain})

      assert {:ok, %{"kind" => "readme", "content" => "# Project"}} =
               Core.call("dir_preview", %{"initiative_id" => id, "path" => plain})
    end

    test "falls back to a tree when there is no README", %{initiative_id: id, tmp_dir: tmp} do
      plain = Path.join(tmp, "plain")
      File.mkdir_p!(Path.join(plain, "lib"))
      File.write!(Path.join([plain, "lib", "app.ex"]), "x")
      {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => plain})

      assert {:ok, %{"kind" => "tree", "entries" => entries}} =
               Core.call("dir_preview", %{"initiative_id" => id, "path" => plain})

      assert Enum.map(entries, & &1["path"]) == ["lib", "lib/app.ex"]
    end

    test "previews the worktree, not the source repo, for an isolated dir",
         %{initiative_id: id, tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)
      File.write!(Path.join(repo, "README.md"), "# Committed")
      GitRepo.commit!(repo, "add readme")

      {:ok, %{"dirs" => [dir]}} =
        Core.call("add_dir", %{"initiative_id" => id, "dir" => repo, "worktree" => true})

      # Only the source repo gets this file; the worktree was branched before it.
      File.write!(Path.join(repo, "README.md"), "# Uncommitted local edit")

      assert {:ok, %{"kind" => "readme", "content" => "# Committed", "dir" => preview_dir}} =
               Core.call("dir_preview", %{"initiative_id" => id, "path" => repo})

      assert preview_dir == dir["worktree_path"]
    end

    test "refuses a directory the initiative does not hold", %{initiative_id: id, tmp_dir: tmp} do
      assert {:error, message} =
               Core.call("dir_preview", %{"initiative_id" => id, "path" => tmp})

      assert message =~ "not part of this initiative"
    end
  end

  describe "list_context_files" do
    # The worktree checkout lives *inside* the initiative's context folder, so
    # without an explicit skip it surfaced as a phantom `worktrees/<slug>/`
    # document — a directory the file reader then refused to open.
    test "does not offer a worktree checkout as a context file",
         %{initiative_id: id, tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)

      {:ok, %{"dirs" => [dir]}} =
        Core.call("add_dir", %{"initiative_id" => id, "dir" => repo, "worktree" => true})

      assert dir["worktree_enabled"], "expected the worktree to be created for this test"

      assert {:ok, %{"files" => files}} =
               Core.call("list_context_files", %{"initiative_id" => id})

      assert "initiative.md" in files
      refute Enum.any?(files, &String.starts_with?(&1, "worktrees"))
    end
  end
end
