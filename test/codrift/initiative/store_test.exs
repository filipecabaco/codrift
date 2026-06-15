defmodule Codrift.Initiative.StoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative
  alias Codrift.Initiative.{DirEntry, Store}

  @moduletag :tmp_dir

  # Use a dedicated ctx/ subdirectory so clean_orphaned_context_dirs does not
  # accidentally remove test directories (e.g. repo/) that happen to live at
  # the same level as tmp_dir.
  defp start_store(tmp_dir) do
    ctx = Path.join(tmp_dir, "ctx")
    File.mkdir_p!(ctx)
    path = Path.join(tmp_dir, "initiatives.json")
    start_supervised!({Store, path: path, name: nil, context_dir_base: ctx})
  end

  defp store_opts(tmp_dir) do
    ctx = Path.join(tmp_dir, "ctx")
    File.mkdir_p!(ctx)
    [path: Path.join(tmp_dir, "initiatives.json"), name: nil, context_dir_base: ctx]
  end

  describe "create/3" do
    test "creates an initiative with generated id and timestamp", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, %Initiative{id: id, name: "My Project", dirs: []}} =
               Store.create("My Project", [], store)

      assert is_binary(id) and byte_size(id) == 16
    end

    test "creates an initiative with dirs as DirEntry structs", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, %Initiative{dirs: [%DirEntry{path: "/home/user/project"}]}} =
               Store.create("With Dirs", ["/home/user/project"], store)
    end
  end

  describe "get/2" do
    test "returns the initiative by id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)
      assert {:ok, %Initiative{name: "Test"}} = Store.get(id, store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.get("nonexistent", store)
    end
  end

  describe "list/1" do
    test "returns empty list when no initiatives", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert [] = Store.list(store)
    end

    test "returns all initiatives sorted by created_at", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, first} = Store.create("First", [], store)
      :timer.sleep(2)
      {:ok, second} = Store.create("Second", [], store)

      assert [%{name: "First"}, %{name: "Second"}] = Store.list(store)
      assert DateTime.compare(first.created_at, second.created_at) == :lt
    end
  end

  describe "add_dir/3" do
    test "adds a directory as a DirEntry", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)

      assert {:ok, %Initiative{dirs: [%DirEntry{path: "/new/dir", worktree_enabled: false}]}} =
               Store.add_dir(id, "/new/dir", store)
    end

    test "is idempotent — duplicate paths are ignored", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", [], store)
      Store.add_dir(id, "/dir", store)

      assert {:ok, %Initiative{dirs: [%DirEntry{path: "/dir"}]}} =
               Store.add_dir(id, "/dir", store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.add_dir("bad", "/dir", store)
    end
  end

  describe "add_dir/4 with worktree_enabled: true" do
    test "creates a worktree when the source dir is a git repo", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Worktree Test", [], store)

      assert {:ok, %Initiative{dirs: [entry]}} =
               Store.add_dir(id, repo, [worktree_enabled: true], store)

      assert %DirEntry{path: ^repo, worktree_enabled: true, worktree_path: wt_path} = entry
      assert is_binary(wt_path)
      assert File.dir?(wt_path)
    end

    test "falls back to plain DirEntry when git worktree add fails", %{tmp_dir: tmp_dir} do
      non_git = Path.join(tmp_dir, "not-a-repo")
      File.mkdir_p!(non_git)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Fallback Test", [], store)

      assert {:ok, %Initiative{dirs: [entry]}} =
               Store.add_dir(id, non_git, [worktree_enabled: true], store)

      assert %DirEntry{path: ^non_git, worktree_enabled: false, worktree_path: nil} = entry
    end
  end

  describe "remove_dir/3" do
    test "removes a directory from an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", ["/a", "/b"], store)

      assert {:ok, %Initiative{dirs: [%DirEntry{path: "/a"}]}} =
               Store.remove_dir(id, "/b", store)
    end

    test "is a no-op when dir is not present", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Test", ["/a"], store)

      assert {:ok, %Initiative{dirs: [%DirEntry{path: "/a"}]}} =
               Store.remove_dir(id, "/nonexistent", store)
    end

    test "removes the worktree when the dir had one", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("WT Remove", [], store)
      {:ok, %Initiative{dirs: [entry]}} = Store.add_dir(id, repo, [worktree_enabled: true], store)
      wt_path = entry.worktree_path
      assert File.dir?(wt_path)

      assert {:ok, %Initiative{dirs: []}} = Store.remove_dir(id, repo, store)
      refute File.dir?(wt_path)
    end
  end

  describe "delete/2" do
    test "removes an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("To Delete", [], store)
      assert :ok = Store.delete(id, store)
      assert {:error, :not_found} = Store.get(id, store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.delete("bad", store)
    end

    test "removes worktrees when deleting an initiative", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("WT Delete", [], store)
      {:ok, %Initiative{dirs: [entry]}} = Store.add_dir(id, repo, [worktree_enabled: true], store)
      wt_path = entry.worktree_path
      assert File.dir?(wt_path)

      assert :ok = Store.delete(id, store)
      refute File.dir?(wt_path)
    end
  end

  describe "set_status/3" do
    test "updates the status of an existing initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Status Test", [], store)

      assert {:ok, %Initiative{status: :done}} = Store.set_status(id, :done, store)
      assert {:ok, %Initiative{status: :done}} = Store.get(id, store)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.set_status("bad", :done, store)
    end
  end

  describe "link_integration/4" do
    test "stores service and item_id on the initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Linked", [], store)

      assert {:ok, %Initiative{integration: %{service: "github", item_id: "owner/repo#5"}}} =
               Store.link_integration(id, "github", "owner/repo#5", store)
    end

    test "integration persists across Store restart", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store1 = start_supervised!({Store, opts}, id: :s1)
      {:ok, %{id: id}} = Store.create("Linked", [], store1)
      Store.link_integration(id, "linear", "ENG-42", store1)
      stop_supervised!(:s1)

      store2 = start_supervised!({Store, opts}, id: :s2)

      assert {:ok, %Initiative{integration: %{service: "linear", item_id: "ENG-42"}}} =
               Store.get(id, store2)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.link_integration("bad", "github", "x", store)
    end
  end

  describe "persistence" do
    test "data survives process restart", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)

      store1 = start_supervised!({Store, opts}, id: :store1)
      {:ok, %{id: id}} = Store.create("Persistent", ["/dir"], store1)
      stop_supervised!(:store1)

      store2 = start_supervised!({Store, opts}, id: :store2)

      assert {:ok, %Initiative{name: "Persistent", dirs: [%DirEntry{path: "/dir"}]}} =
               Store.get(id, store2)
    end

    test "worktree_path survives process restart", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      opts = store_opts(tmp_dir)

      store1 = start_supervised!({Store, opts}, id: :store1)
      {:ok, %{id: id}} = Store.create("WT Persist", [], store1)

      {:ok, %Initiative{dirs: [entry1]}} =
        Store.add_dir(id, repo, [worktree_enabled: true], store1)

      stop_supervised!(:store1)

      store2 = start_supervised!({Store, opts}, id: :store2)

      assert {:ok, %Initiative{dirs: [entry2]}} = Store.get(id, store2)
      assert entry2.worktree_path == entry1.worktree_path
      assert entry2.worktree_enabled == true
    end

    test "writes valid JSON to the configured path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "initiatives.json")
      store = start_store(tmp_dir)
      Store.create("JSON Test", [], store)

      assert {:ok, content} = File.read(path)
      assert {:ok, %{"initiatives" => _}} = JSON.decode(content)
    end
  end

  describe "set_worktree_default/3" do
    test "sets worktree_default on an initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("WT Default", [], store)

      assert {:ok, %Initiative{worktree_default: true}} =
               Store.set_worktree_default(id, true, store)

      assert {:ok, %Initiative{worktree_default: true}} = Store.get(id, store)
    end

    test "persists across Store restart", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store1 = start_supervised!({Store, opts}, id: :s1)
      {:ok, %{id: id}} = Store.create("WT Persist", [], store1)
      Store.set_worktree_default(id, true, store1)
      stop_supervised!(:s1)

      store2 = start_supervised!({Store, opts}, id: :s2)
      assert {:ok, %Initiative{worktree_default: true}} = Store.get(id, store2)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.set_worktree_default("bad", true, store)
    end
  end

  describe "toggle_dir_worktree/3" do
    test "enables worktree on a dir that has none", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Toggle On", [], store)
      Store.add_dir(id, repo, store)

      assert {:ok, %Initiative{dirs: [entry]}} = Store.toggle_dir_worktree(id, repo, store)
      assert entry.worktree_enabled == true
      assert is_binary(entry.worktree_path)
      assert File.dir?(entry.worktree_path)
    end

    test "disables worktree on a dir that has one", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Toggle Off", [], store)
      {:ok, %Initiative{dirs: [entry]}} = Store.add_dir(id, repo, [worktree_enabled: true], store)
      wt_path = entry.worktree_path
      assert File.dir?(wt_path)

      assert {:ok, %Initiative{dirs: [cleared]}} = Store.toggle_dir_worktree(id, repo, store)
      assert cleared.worktree_enabled == false
      assert is_nil(cleared.worktree_path)
      refute File.dir?(wt_path)
    end

    test "enable falls back to plain entry when source is not a git repo", %{tmp_dir: tmp_dir} do
      not_git = Path.join(tmp_dir, "plain")
      File.mkdir_p!(not_git)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Not Git", [], store)
      Store.add_dir(id, not_git, store)

      assert {:ok, %Initiative{dirs: [entry]}} =
               Store.toggle_dir_worktree(id, not_git, store)

      assert entry.worktree_enabled == false
      assert is_nil(entry.worktree_path)
    end

    test "returns :not_found for unknown initiative id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.toggle_dir_worktree("bad", "/any", store)
    end

    test "returns :not_found when dir is not in the initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("No Dir", [], store)
      assert {:error, :not_found} = Store.toggle_dir_worktree(id, "/nonexistent", store)
    end
  end

  describe "orchestration.md" do
    test "is created when an initiative is created", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Orch Test", [], store)
      # Sync: handle_continue runs before the next GenServer call processes
      Store.get(id, store)

      path = Path.join([tmp_dir, "ctx", id, "orchestration.md"])
      assert File.exists?(path)
    end

    test "contains the initiative name", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("My Initiative", [], store)
      Store.get(id, store)

      content = File.read!(Path.join([tmp_dir, "ctx", id, "orchestration.md"]))
      assert String.contains?(content, "My Initiative")
    end

    test "is not overwritten when it already exists (user edits preserved)", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Editable", [], store)
      # Sync before writing to the path to avoid a race with handle_continue
      Store.get(id, store)

      path = Path.join([tmp_dir, "ctx", id, "orchestration.md"])
      File.write!(path, "custom user content")

      # Trigger another write by restarting the store (which calls write_orchestration_md on init)
      opts = store_opts(tmp_dir)
      stop_supervised!(Codrift.Initiative.Store)
      store2 = start_supervised!({Store, opts}, id: :s2)
      _ = Store.list(store2)

      assert File.read!(path) == "custom user content"
    end

    test "is backfilled on Store restart for pre-existing initiatives", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store1 = start_supervised!({Store, opts}, id: :store1)
      {:ok, %{id: id}} = Store.create("Backfill", [], store1)
      # Sync before deleting to ensure handle_continue has created the file first
      Store.get(id, store1)

      path = Path.join([tmp_dir, "ctx", id, "orchestration.md"])
      File.rm!(path)
      refute File.exists?(path)

      stop_supervised!(:store1)
      start_supervised!({Store, opts}, id: :store2)

      assert File.exists?(path)
    end
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
end
