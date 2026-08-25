defmodule Codrift.CLI.InitiativeCommandsTest do
  @moduledoc """
  The rest of `codrift initiative` — real files, real git repositories, no stubs.

  This CLI is the release `eval` entrypoint: it reads and writes
  `initiatives.json` directly rather than through the Store GenServer, because
  it runs in a short-lived process that must not fight the desktop app for the
  port. That means it is a *second implementation* of the same state, and the
  thing worth pinning is that the two agree — a status this writes must be one
  the app can read back, and a directory added here must look like one added
  there.

  `Codrift.CLI.InitiativeTest` covers list and create; this covers everything
  after that. `fail/1` paths call `System.halt/1` and are left alone, as in
  every other CLI suite here.

  Not `async`: writes the shared sandbox `initiatives.json`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Codrift.CLI.Initiative, as: CLI
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  defp run_json(argv) do
    capture_io(fn -> CLI.run(argv) end) |> String.trim() |> JSON.decode!()
  end

  setup do
    created = run_json(["create", "cli-cmd-#{System.unique_integer([:positive])}"])
    id = created["id"]
    on_exit(fn -> capture_io(fn -> CLI.run(["delete", id]) end) end)
    {:ok, id: id, initiative: created}
  end

  describe "show" do
    test "returns the same shape list does, for one initiative", %{id: id} do
      shown = run_json(["show", id])
      listed = run_json(["list"])["initiatives"] |> Enum.find(&(&1["id"] == id))

      assert shown["id"] == id
      assert shown == listed
    end
  end

  describe "add-dir" do
    test "records the directory, expanded to an absolute path", %{id: id, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)

      updated = run_json(["add-dir", id, project])

      assert Enum.any?(updated["dirs"], &(&1["path"] == project))
    end

    test "adding the same directory twice does not duplicate it", %{id: id, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)

      run_json(["add-dir", id, project])
      updated = run_json(["add-dir", id, project])

      assert Enum.count(updated["dirs"], &(&1["path"] == project)) == 1
    end

    test "a relative path is expanded, so the stored entry is unambiguous", %{id: id} do
      # An entry that kept "./project" would resolve against whatever directory
      # the next process happened to start in.
      updated = run_json(["add-dir", id, "."])

      assert Enum.any?(updated["dirs"], &(&1["path"] == File.cwd!()))
    end
  end

  describe "status" do
    test "each valid status round-trips", %{id: id} do
      for status <- ~w[planning ongoing done archived] do
        assert run_json(["status", id, status])["status"] == status
        assert run_json(["show", id])["status"] == status
      end
    end
  end

  describe "worktree-enable and worktree-disable" do
    setup %{id: id, tmp_dir: tmp_dir} do
      repo = GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"README.md" => "hi"})
      run_json(["add-dir", id, repo])
      {:ok, repo: repo}
    end

    test "enabling creates a real checkout and records where it is",
         %{id: id, repo: repo} do
      updated = run_json(["worktree-enable", id, repo])
      entry = Enum.find(updated["dirs"], &(&1["path"] == repo))

      assert entry["worktree_enabled"]
      assert is_binary(entry["worktree_path"])
      assert File.dir?(entry["worktree_path"]), "the worktree was recorded but never created"

      # A worktree is a checkout of the same repository, so the committed file
      # is there — that is what distinguishes it from an empty directory.
      assert File.regular?(Path.join(entry["worktree_path"], "README.md"))
    end

    test "disabling clears the flag and leaves the source repository alone",
         %{id: id, repo: repo} do
      run_json(["worktree-enable", id, repo])
      updated = run_json(["worktree-disable", id, repo])

      entry = Enum.find(updated["dirs"], &(&1["path"] == repo))
      refute entry["worktree_enabled"]

      # Removing a worktree must never touch the checkout the user works in.
      assert File.regular?(Path.join(repo, "README.md"))
    end

    test "worktree-status reports each directory", %{id: id, repo: repo} do
      run_json(["worktree-enable", id, repo])
      status = run_json(["worktree-status", id])

      assert is_map(status) or is_list(status)
      assert status |> JSON.encode!() |> String.contains?(repo)
    end

    # Two cases are deliberately absent, both because they end in `fail/1` →
    # `System.halt/1`, which takes the test VM with it: enabling on a plain
    # folder, and enabling a second time on the same directory.
    #
    # The second is worth knowing about. `Core.call("set_dir_worktree", …)` is
    # idempotent by design — an agent asking twice must not create and then
    # destroy — while this CLI refuses with "worktree already enabled". Two
    # implementations of one operation that disagree about whether repeating it
    # is an error; `Codrift.CoreWorktreeTest` pins the Core half.
  end

  describe "allow-read and revoke-read" do
    test "granting and revoking both report per-directory results",
         %{id: id, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)
      run_json(["add-dir", id, project])

      granted = run_json(["allow-read", id])
      revoked = run_json(["revoke-read", id])

      for result <- [granted, revoked] do
        assert result |> JSON.encode!() |> String.contains?(project)
      end
    end

    test "an initiative with no directories is not an error", %{id: id} do
      assert is_map(run_json(["allow-read", id])) or is_list(run_json(["allow-read", id]))
    end
  end

  describe "delete" do
    test "removes the entry and its context folder" do
      created = run_json(["create", "to-be-deleted-#{System.unique_integer([:positive])}"])
      id = created["id"]
      context = Codrift.Paths.initiative_dir(id)

      assert File.dir?(context)
      assert %{"deleted" => ^id} = run_json(["delete", id])

      refute File.dir?(context)
      refute Enum.any?(run_json(["list"])["initiatives"], &(&1["id"] == id))
    end
  end

  describe "usage" do
    test "an unrecognised subcommand lists the commands" do
      output = capture_io(fn -> CLI.run(["nonsense"]) end)

      for command <- ~w[list show create add-dir status delete] do
        assert output =~ command, "usage omitted #{command}"
      end
    end
  end
end
