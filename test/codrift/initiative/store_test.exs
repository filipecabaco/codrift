defmodule Codrift.Initiative.StoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Initiative
  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.Test.GitRepo

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

  # Context folders are written from a handle_continue, so the reply lands before
  # the files do. Any call flushes it.
  defp sync(store), do: Store.list(store)

  defp store_opts(tmp_dir) do
    ctx = Path.join(tmp_dir, "ctx")
    File.mkdir_p!(ctx)
    [path: Path.join(tmp_dir, "initiatives.json"), name: nil, context_dir_base: ctx]
  end

  # An initiative changed by an MCP agent or a second window has to reach every
  # open window, and until these events existed nothing told them. Ids are pinned
  # in every assertion because the watcher registry is global: other async tests
  # broadcast into the same mailbox.
  describe "change notification" do
    setup do
      Registry.register(Codrift.AgentWatchers, :all, nil)
      :ok
    end

    test "create announces a creation, not an update", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      {:ok, %Initiative{id: id}} = Store.create("Announced", [], store)

      assert_receive {:initiative_created, %Initiative{id: ^id, name: "Announced"}}
    end

    test "a status change announces an update", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create("Cycling", [], store)

      {:ok, _} = Store.set_status(id, :done, store)

      assert_receive {:initiative_updated, %Initiative{id: ^id, status: :done}}
    end

    # add_dir does not call put_initiative directly — it goes through
    # update_initiative — which is exactly why the broadcast lives in the funnel
    # rather than being repeated per mutation.
    test "adding a directory announces an update", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create("Growing", [], store)
      dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(dir)

      {:ok, _} = Store.add_dir(id, dir, store)

      assert_receive {:initiative_updated, %Initiative{id: ^id, dirs: [%DirEntry{path: ^dir}]}}
    end

    test "delete announces a deletion", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create("Doomed", [], store)

      :ok = Store.delete(id, store)

      assert_receive {:initiative_deleted, ^id}
    end
  end

  describe "reload/1" do
    setup do
      Registry.register(Codrift.AgentWatchers, :all, nil)
      :ok
    end

    defp write_json!(path, initiatives) do
      data = Map.new(initiatives, fn i -> {i.id, Initiative.to_map(i)} end)
      File.write!(path, JSON.encode!(%{"initiatives" => data}))
    end

    test "picks up a write made outside this process", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store = start_supervised!({Store, opts})
      external = Initiative.new("Written by the CLI")
      write_json!(opts[:path], [external])

      reloaded = Store.reload(store)

      id = external.id
      assert Enum.any?(reloaded, &(&1.id == id))
      assert_receive {:initiative_created, %Initiative{id: ^id}}
    end

    test "announces nothing when the file matches state", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create("Steady", [], store)
      assert_receive {:initiative_created, %Initiative{id: ^id}}

      Store.reload(store)

      refute_receive {:initiative_updated, %Initiative{id: ^id}}, 100
    end
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

  describe "create_scratch/3 and promote/3" do
    test "a scratchpad is an ordinary initiative carrying the flag", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, %Initiative{id: id, scratch: true, status: :ongoing}} =
               Store.create_scratch("scratch 09:41", [], store)

      # It gets the same context folder as any other initiative — that is what
      # makes promoting one a rename rather than a migration.
      sync(store)
      assert File.dir?(Path.join([tmp_dir, "ctx", id]))
    end

    test "a scratchpad can carry the directory it was opened against",
         %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:ok, %Initiative{scratch: true, dirs: [%DirEntry{path: "/home/user/api"}]}} =
               Store.create_scratch("scratch · api 09:41", ["/home/user/api"], store)
    end

    test "create/3 does not set the flag", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:ok, %Initiative{scratch: false}} = Store.create("Real work", [], store)
    end

    test "promote/3 renames, clears the flag and keeps the id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create_scratch("scratch 09:41", [], store)

      assert {:ok, %Initiative{id: ^id, name: "Ship the parser", scratch: false}} =
               Store.promote(id, "Ship the parser", store)

      assert {:ok, %Initiative{name: "Ship the parser", scratch: false}} = Store.get(id, store)
    end

    test "the new name reaches initiative.md, leaving the rest of it alone",
         %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create_scratch("scratch 09:41", [], store)
      sync(store)

      md = Path.join([tmp_dir, "ctx", id, "initiative.md"])
      File.write!(md, File.read!(md) <> "\n## Notes\n\nsomething the user wrote\n")

      {:ok, _} = Store.promote(id, "Ship the parser", store)
      sync(store)

      content = File.read!(md)
      assert content =~ "# Ship the parser"
      assert content =~ "Name: Ship the parser"
      refute content =~ "scratch 09:41"
      # The whole file is the user's except the two name lines.
      assert content =~ "something the user wrote"
      assert content =~ "ID: #{id}"
    end

    test "rename/3 leaves a real initiative real", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %Initiative{id: id}} = Store.create("Old name", [], store)

      assert {:ok, %Initiative{name: "New name", scratch: false}} =
               Store.rename(id, "New name", store)
    end

    test "renaming something that is not there is an error, not a crash",
         %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.promote("nope", "Anything", store)
      assert {:error, :not_found} = Store.rename("nope", "Anything", store)
    end

    test "the flag survives a restart", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store = start_supervised!({Store, opts}, id: :first)
      {:ok, %Initiative{id: id}} = Store.create_scratch("scratch 09:41", [], store)
      stop_supervised!(:first)

      reopened = start_supervised!({Store, opts}, id: :second)
      assert {:ok, %Initiative{scratch: true}} = Store.get(id, reopened)
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

  describe "initiative.md directory block" do
    # The regression that emptied every worktree: agents read this block to learn
    # where to work, so naming the source path here sent them into the working
    # copy the worktree was created to protect — leaving the checkout untouched
    # and the diff view (which reads it) blank.
    test "names the worktree, not the source, when one is active", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Worktree Docs", [], store)
      {:ok, %Initiative{dirs: [entry]}} = Store.add_dir(id, repo, [worktree_enabled: true], store)
      sync(store)

      md = File.read!(Path.join([tmp_dir, "ctx", id, "initiative.md"]))
      block = Regex.run(~r/<!-- codrift:dirs:start -->.*?<!-- codrift:dirs:end -->/s, md) |> hd()

      assert block =~ Codrift.Paths.compact(entry.worktree_path)
      assert block =~ "work here"
      # The source is still named, but only as the thing being isolated.
      assert block =~ "must be left untouched"
    end

    test "a stale block is re-rendered on boot, so existing initiatives migrate",
         %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Legacy", [], store)
      {:ok, %Initiative{dirs: [entry]}} = Store.add_dir(id, repo, [worktree_enabled: true], store)
      sync(store)

      md = Path.join([tmp_dir, "ctx", id, "initiative.md"])

      # Simulate an initiative written by the version that named the source path.
      stale =
        Regex.replace(
          ~r/<!-- codrift:dirs:start -->.*?<!-- codrift:dirs:end -->/s,
          File.read!(md),
          "<!-- codrift:dirs:start -->\n## Directories\n\n- #{entry.path}\n<!-- codrift:dirs:end -->"
        )

      File.write!(md, stale)
      refute File.read!(md) =~ "work here"

      # Restarting the store must heal it without any user action.
      start_supervised!({Store, store_opts(tmp_dir)}, id: :rebooted)

      assert File.read!(md) =~ Codrift.Paths.compact(entry.worktree_path)
      assert File.read!(md) =~ "work here"
    end

    test "names the source path when there is no worktree", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Plain Docs", [], store)
      {:ok, _} = Store.add_dir(id, "/home/user/project", store)
      sync(store)

      md = File.read!(Path.join([tmp_dir, "ctx", id, "initiative.md"]))
      block = Regex.run(~r/<!-- codrift:dirs:start -->.*?<!-- codrift:dirs:end -->/s, md) |> hd()

      assert block =~ "/home/user/project"
      refute block =~ "work here"
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

  describe "link_integration/3" do
    test "stores service and item_id on the initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Linked", [], store)

      assert {:ok, %Initiative{integration: %{service: "github", item_id: "owner/repo#5"}}} =
               Store.link_integration(id, %{service: "github", item_id: "owner/repo#5"}, store)
    end

    test "integration persists across Store restart", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      store1 = start_supervised!({Store, opts}, id: :s1)
      {:ok, %{id: id}} = Store.create("Linked", [], store1)
      Store.link_integration(id, %{service: "linear", item_id: "ENG-42"}, store1)
      stop_supervised!(:s1)

      store2 = start_supervised!({Store, opts}, id: :s2)

      assert {:ok, %Initiative{integration: %{service: "linear", item_id: "ENG-42"}}} =
               Store.get(id, store2)
    end

    test "returns :not_found for unknown id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)

      assert {:error, :not_found} =
               Store.link_integration("bad", %{service: "github", item_id: "x"}, store)
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

    test "leaves no temp file behind after persisting", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "initiatives.json")
      store = start_store(tmp_dir)
      Store.create("Atomic", [], store)

      assert File.exists?(path)
      refute File.exists?(path <> ".tmp")
    end

    test "backs up a corrupt file and starts empty", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      path = opts[:path]
      File.write!(path, "{truncated")

      store = start_supervised!({Store, opts})

      assert [] = Store.list(store)
      assert File.read!(path <> ".corrupt") == "{truncated"
    end

    test "does not prune context dirs when the file is corrupt", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      orphan = Path.join(opts[:context_dir_base], "would-be-orphan")
      File.mkdir_p!(orphan)
      File.write!(opts[:path], "not json at all")

      start_supervised!({Store, opts})

      assert File.dir?(orphan)
    end

    test "prunes orphaned context dirs when the file loads cleanly", %{tmp_dir: tmp_dir} do
      opts = store_opts(tmp_dir)
      orphan = Path.join(opts[:context_dir_base], "stale-initiative-id")
      File.mkdir_p!(orphan)

      store = start_supervised!({Store, opts}, id: :store1)
      Store.create("Real", [], store)
      stop_supervised!(:store1)

      orphan2 = Path.join(opts[:context_dir_base], "stale-initiative-id")
      File.mkdir_p!(orphan2)
      start_supervised!({Store, opts}, id: :store2)

      refute File.dir?(orphan2)
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

  describe "set_dir_worktree/4" do
    test "enables worktree on a dir that has none", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Toggle On", [], store)
      Store.add_dir(id, repo, store)

      assert {:ok, %Initiative{dirs: [entry]}} = Store.set_dir_worktree(id, repo, true, store)
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

      assert {:ok, %Initiative{dirs: [cleared]}} = Store.set_dir_worktree(id, repo, false, store)
      assert cleared.worktree_enabled == false
      assert is_nil(cleared.worktree_path)
      refute File.dir?(wt_path)
    end

    # add_dir(worktree_enabled: true) still degrades to a plain entry — adding a
    # directory should not fail because one of its options could not be honoured.
    # Asking for a worktree explicitly is different: the caller wants that
    # outcome, so it gets git's reason instead of a silent no-op.
    test "reports why when the source is not a git repository", %{tmp_dir: tmp_dir} do
      not_git = Path.join(tmp_dir, "plain")
      File.mkdir_p!(not_git)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Not Git", [], store)
      Store.add_dir(id, not_git, store)

      assert {:error, {:worktree_failed, reason}} =
               Store.set_dir_worktree(id, not_git, true, store)

      assert reason =~ "not a git repository"
    end

    # An agent that retries, or two that both ask, must not create a worktree and
    # then destroy it.
    test "asking for the state it is already in changes nothing", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo)
      init_git_repo(repo)

      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("Idempotent", [], store)
      Store.add_dir(id, repo, store)

      {:ok, %Initiative{dirs: [entry]}} = Store.set_dir_worktree(id, repo, true, store)
      assert {:ok, %Initiative{dirs: [^entry]}} = Store.set_dir_worktree(id, repo, true, store)
      assert File.dir?(entry.worktree_path)

      {:ok, _} = Store.set_dir_worktree(id, repo, false, store)

      assert {:ok, %Initiative{dirs: [%DirEntry{worktree_path: nil}]}} =
               Store.set_dir_worktree(id, repo, false, store)
    end

    test "returns :not_found for unknown initiative id", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      assert {:error, :not_found} = Store.set_dir_worktree("bad", "/any", true, store)
    end

    test "returns :not_found when dir is not in the initiative", %{tmp_dir: tmp_dir} do
      store = start_store(tmp_dir)
      {:ok, %{id: id}} = Store.create("No Dir", [], store)
      assert {:error, :not_found} = Store.set_dir_worktree(id, "/nonexistent", true, store)
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

  defp init_git_repo(path), do: GitRepo.init!(path)
end
