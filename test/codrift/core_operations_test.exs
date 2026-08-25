defmodule Codrift.CoreOperationsTest do
  @moduledoc """
  The operations `Codrift.Core` exposes that nothing else covered: renaming and
  promoting, scratchpads, the folderless workspace, the git wrappers, and the
  guards on the ones that reach the network.

  `Core.call/2` is the single surface behind MCP, the JSON API and the UI, so an
  operation that raises instead of returning `{:error, message}` becomes a 500
  for an agent and a dead button for a person. The error paths here matter as
  much as the happy ones.

  Not `async`: uses the global `Codrift.Initiative.Store`.
  """
  use ExUnit.Case, async: false

  alias Codrift.Core
  alias Codrift.Initiative.Store
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  setup do
    created = fn name ->
      {:ok, initiative} = Core.call("create_initiative", %{"name" => name})
      on_exit(fn -> Store.delete(initiative["id"]) end)
      initiative
    end

    {:ok, create: created}
  end

  describe "rename_initiative" do
    test "renames, and the new name is what the list reports", %{create: create} do
      id = create.("before")["id"]

      assert {:ok, %{"name" => "after"}} =
               Core.call("rename_initiative", %{"initiative_id" => id, "name" => "after"})

      assert {:ok, initiatives} = Core.call("list_initiatives", %{})
      assert Enum.any?(initiatives, &(&1["id"] == id and &1["name"] == "after"))
    end

    test "trims, so a stray space cannot create a name nothing matches", %{create: create} do
      id = create.("before")["id"]

      assert {:ok, %{"name" => "spaced"}} =
               Core.call("rename_initiative", %{"initiative_id" => id, "name" => "  spaced  "})
    end

    test "refuses a blank name rather than storing an unnameable initiative", %{create: create} do
      id = create.("before")["id"]

      assert {:error, message} =
               Core.call("rename_initiative", %{"initiative_id" => id, "name" => "   "})

      assert message =~ "empty"
    end

    test "reports an unknown initiative" do
      assert {:error, message} =
               Core.call("rename_initiative", %{"initiative_id" => "nope", "name" => "x"})

      assert message =~ "not found"
    end
  end

  describe "create_scratchpad and promote_initiative" do
    test "a scratchpad is created named for itself, and is marked scratch" do
      assert {:ok, %{"id" => id, "scratch" => true, "name" => name}} =
               Core.call("create_scratchpad", %{})

      on_exit(fn -> Store.delete(id) end)
      assert is_binary(name) and name != ""
    end

    test "a scratchpad opened on a directory adopts it", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "somewhere")
      File.mkdir_p!(dir)

      assert {:ok, %{"id" => id, "dirs" => dirs}} =
               Core.call("create_scratchpad", %{"dirs" => [dir]})

      on_exit(fn -> Store.delete(id) end)
      assert Enum.any?(dirs, &(&1["path"] == dir))
    end

    test "promoting names it and clears the scratch flag" do
      {:ok, %{"id" => id}} = Core.call("create_scratchpad", %{})
      on_exit(fn -> Store.delete(id) end)

      assert {:ok, %{"name" => "real work", "scratch" => false}} =
               Core.call("promote_initiative", %{"initiative_id" => id, "name" => "  real work  "})
    end

    test "promoting to a blank name is refused" do
      {:ok, %{"id" => id}} = Core.call("create_scratchpad", %{})
      on_exit(fn -> Store.delete(id) end)

      assert {:error, message} =
               Core.call("promote_initiative", %{"initiative_id" => id, "name" => ""})

      assert message =~ "empty"
    end

    test "promoting an unknown initiative reports it" do
      assert {:error, message} =
               Core.call("promote_initiative", %{"initiative_id" => "nope", "name" => "x"})

      assert message =~ "not found"
    end
  end

  describe "add_context_workspace" do
    test "adopts the initiative's own folder, so a folderless one can still run", %{
      create: create
    } do
      id = create.("scratch-workspace")["id"]

      assert {:ok, %{"dirs" => dirs}} =
               Core.call("add_context_workspace", %{"initiative_id" => id})

      assert Enum.any?(dirs, &(&1["path"] == Store.context_path(id)))
    end

    test "reports an unknown initiative" do
      assert {:error, message} = Core.call("add_context_workspace", %{"initiative_id" => "nope"})
      assert message =~ "not found"
    end
  end

  describe "the git wrappers" do
    setup %{create: create, tmp_dir: tmp_dir} do
      id = create.("git-ops")["id"]
      repo = GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"file.txt" => "one\n"})
      {:ok, _} = Core.call("add_dir", %{"initiative_id" => id, "dir" => repo})
      {:ok, id: id, repo: repo}
    end

    test "git_info finds the initiative's only repository without being told which",
         %{id: id, repo: repo} do
      assert {:ok, info} = Core.call("git_info", %{"initiative_id" => id})

      assert info["dir"] == repo
      assert is_binary(info["branch"])
      assert info["ahead"] == 0 and info["behind"] == 0
      assert info["upstream"] == nil
    end

    test "git_info sees a dirty tree", %{id: id, repo: repo} do
      File.write!(Path.join(repo, "file.txt"), "changed\n")
      assert {:ok, %{"dirty" => true}} = Core.call("git_info", %{"initiative_id" => id})
    end

    test "git_commit lands the change and reports the sha", %{id: id, repo: repo} do
      File.write!(Path.join(repo, "file.txt"), "changed\n")

      assert {:ok, %{"sha" => sha, "branch" => branch}} =
               Core.call("git_commit", %{"initiative_id" => id, "message" => "from core"})

      assert is_binary(sha) and is_binary(branch)
      assert {:ok, %{"dirty" => false}} = Core.call("git_info", %{"initiative_id" => id})
    end

    test "git_commit refuses an empty message", %{id: id, repo: repo} do
      File.write!(Path.join(repo, "file.txt"), "changed\n")

      assert {:error, message} =
               Core.call("git_commit", %{"initiative_id" => id, "message" => "  "})

      assert message =~ "message is required"
    end

    test "git_rebase says what it cannot do rather than raising", %{id: id} do
      # No upstream and no origin/HEAD: the honest answer is "fetch first", not
      # a crash from git's own exit code.
      assert {:error, message} = Core.call("git_rebase", %{"initiative_id" => id})
      assert message =~ "upstream" or message =~ "rebase"
    end

    test "git_push without a remote reports git's own failure", %{id: id} do
      assert {:error, message} = Core.call("git_push", %{"initiative_id" => id})
      assert message =~ "push failed"
    end

    test "an initiative with no repository is told so", %{create: create} do
      id = create.("no-repo")["id"]

      assert {:error, message} = Core.call("git_info", %{"initiative_id" => id})
      assert message =~ "no git repository"
    end

    test "an unknown initiative is reported, not crashed on" do
      assert {:error, message} = Core.call("git_info", %{"initiative_id" => "nope"})
      assert message =~ "not found"
    end
  end

  describe "open_url" do
    test "refuses anything that is not http(s), so a page cannot launch a file" do
      for url <- ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.test"] do
        assert {:error, message} = Core.call("open_url", %{"url" => url})
        assert message =~ "refusing"
      end
    end
  end

  describe "guards on the operations that reach the network" do
    test "an unknown service is an error for every integration op" do
      for op <- ["list_integration_items", "start_oauth_flow"] do
        assert {:error, _} = Core.call(op, %{"service" => "not-a-service"}),
               "#{op} accepted an unknown service"
      end
    end

    test "sync_initiative_context on an initiative that was never imported" do
      {:ok, %{"id" => id}} = Core.call("create_initiative", %{"name" => "not-imported"})
      on_exit(fn -> Store.delete(id) end)

      assert {:error, message} = Core.call("sync_initiative_context", %{"initiative_id" => id})
      assert is_binary(message)
    end
  end

  describe "unknown operations" do
    test "are an error naming the operation, never a crash" do
      assert {:error, message} = Core.call("no_such_operation", %{})
      assert message =~ "no_such_operation"
    end
  end
end
