defmodule Codrift.CoreWorktreeTest do
  @moduledoc """
  The operations that let an agent see and manage worktrees.

  Worktrees have always lived at `~/.codrift/initiatives/<id>/worktrees/<slug>`,
  but nothing could enumerate them, so one left behind by a deleted initiative
  stayed on disk holding a checkout and a branch that no surface could show.
  What matters here is that `set_dir_worktree` is idempotent (an agent asking
  twice must not create and then destroy), that a failed creation is reported as
  an error rather than as success, and that pruning does nothing without `force`.

  Not `async`: uses the global `Codrift.Initiative.Store`.
  """
  use ExUnit.Case, async: false

  alias Codrift.Core
  alias Codrift.Initiative.Store
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, initiative} = Core.call("create_initiative", %{"name" => "worktree-test"})
    id = initiative["id"]
    repo = GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"README.md" => "hi"})
    {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => repo})

    on_exit(fn -> Store.delete(id) end)
    {:ok, id: id, repo: repo}
  end

  defp worktrees_of(id) do
    {:ok, list} = Core.call("list_worktrees", %{"initiative_id" => id})
    list
  end

  describe "set_dir_worktree" do
    test "creates a worktree and lists it as linked", %{id: id, repo: repo} do
      assert {:ok, _} =
               Core.call("set_dir_worktree", %{
                 "initiative_id" => id,
                 "dir" => repo,
                 "enabled" => true
               })

      assert [entry] = worktrees_of(id)
      assert entry["state"] == "linked"
      assert entry["source_path"] == repo
      assert entry["initiative_id"] == id
      assert entry["dirty"] == false
      assert File.dir?(entry["path"])
      assert entry["path"] =~ "/worktrees/"
    end

    # The store's own operation is a toggle. An agent that retries — or two
    # agents that both ask — must not end up destroying the worktree.
    test "asking twice for enabled leaves the worktree in place", %{id: id, repo: repo} do
      args = %{"initiative_id" => id, "dir" => repo, "enabled" => true}
      assert {:ok, _} = Core.call("set_dir_worktree", args)
      [%{"path" => path}] = worktrees_of(id)

      assert {:ok, _} = Core.call("set_dir_worktree", args)

      assert [%{"path" => ^path}] = worktrees_of(id)
      assert File.dir?(path)
    end

    test "disabling removes it, and asking twice is still safe", %{id: id, repo: repo} do
      assert {:ok, _} =
               Core.call("set_dir_worktree", %{
                 "initiative_id" => id,
                 "dir" => repo,
                 "enabled" => true
               })

      off = %{"initiative_id" => id, "dir" => repo, "enabled" => false}
      assert {:ok, _} = Core.call("set_dir_worktree", off)
      assert worktrees_of(id) == []
      assert {:ok, _} = Core.call("set_dir_worktree", off)
      assert worktrees_of(id) == []
    end

    # The store logs and carries on when `git worktree add` fails, leaving the
    # entry untouched — which would read as success to a caller that only checked
    # for {:ok, _}.
    test "a directory that is not a git repository is an error, not a silent no-op", %{
      id: id,
      tmp_dir: tmp_dir
    } do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)
      {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => plain})

      assert {:error, message} =
               Core.call("set_dir_worktree", %{
                 "initiative_id" => id,
                 "dir" => plain,
                 "enabled" => true
               })

      assert message =~ "could not create the worktree"
      assert worktrees_of(id) == []
    end

    test "rejects an unknown initiative and an unknown directory", %{id: id, repo: repo} do
      assert {:error, msg} =
               Core.call("set_dir_worktree", %{"initiative_id" => "nope", "dir" => repo})

      assert msg =~ "initiative not found"

      assert {:error, msg} =
               Core.call("set_dir_worktree", %{"initiative_id" => id, "dir" => "/tmp/never-added"})

      assert msg =~ "not a directory of initiative"
    end
  end

  describe "prune_worktrees" do
    # An orphan is made the way real ones are: a worktree on disk under an
    # initiative id the store has no record of. Going through remove_dir would not
    # produce one — that path cleans the worktree up with the directory, which is
    # the point of it.
    defp orphan_worktree!(tmp_dir, name) do
      id = "deadbeef" <> String.slice(name <> "00000000", 0, 8)
      repo = GitRepo.init_with!(Path.join(tmp_dir, "orphan-#{name}"), %{"README.md" => "x"})
      ctx = Codrift.Paths.initiative_dir(id)
      File.mkdir_p!(ctx)
      {:ok, path} = Codrift.Worktree.ensure(ctx, id, repo)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf(ctx) end)
      path
    end

    test "defaults to a dry run that deletes nothing", %{tmp_dir: tmp_dir} do
      path = orphan_worktree!(tmp_dir, "dry")

      assert {:ok, result} = Core.call("prune_worktrees", %{})

      assert result["dry_run"] == true
      assert result["removed"] == []
      assert Enum.any?(result["orphans"], &(&1["path"] == path))
      assert File.dir?(path), "a dry run must not touch the filesystem"
    end
  end
end
