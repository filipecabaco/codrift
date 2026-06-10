defmodule Codrift.SessionStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.SessionStore

  # Each test gets its own isolated SQLite DB so tests can run concurrently.
  setup %{test: test} do
    db_path = Path.join(System.tmp_dir!(), "codrift_test_#{test}.db")
    on_exit(fn -> File.rm(db_path) end)

    name = :"session_store_#{test}"
    start_supervised!({SessionStore, path: db_path, name: name})

    {:ok, store: name}
  end

  describe "save/6 + get_by_agent/2" do
    test "saves and retrieves a session by agent ID", %{store: store} do
      assert :ok =
               SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-abc", "claude", store)

      assert {:ok, "uuid-abc"} = SessionStore.get_by_agent("agent-1", store)
    end

    test "returns :not_found for unknown agent", %{store: store} do
      assert {:error, :not_found} = SessionStore.get_by_agent("ghost", store)
    end

    test "upserts on repeated save for the same agent", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-old", "claude", store)
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-new", "claude", store)
      assert {:ok, "uuid-new"} = SessionStore.get_by_agent("agent-1", store)
    end

    test "two agents in the same dir store independent sessions", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      :ok = SessionStore.save("agent-2", "init-1", "/work/foo", "uuid-B", "claude", store)

      assert {:ok, "uuid-A"} = SessionStore.get_by_agent("agent-1", store)
      assert {:ok, "uuid-B"} = SessionStore.get_by_agent("agent-2", store)
    end
  end

  describe "list_all/1" do
    test "returns empty list when no sessions saved", %{store: store} do
      assert [] = SessionStore.list_all(store)
    end

    test "returns all sessions as {agent_id, initiative_id, dir, session_id, adapter} tuples", %{
      store: store
    } do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      :ok = SessionStore.save("agent-2", "init-1", "/work/foo", "uuid-B", "opencode", store)
      :ok = SessionStore.save("agent-3", "init-2", "/work/bar", "uuid-C", "claude", store)

      rows = SessionStore.list_all(store)
      assert length(rows) == 3

      assert {"agent-1", "init-1", "/work/foo", "uuid-A", "claude"} in rows
      assert {"agent-2", "init-1", "/work/foo", "uuid-B", "opencode"} in rows
      assert {"agent-3", "init-2", "/work/bar", "uuid-C", "claude"} in rows
    end
  end

  describe "list_by_dir/3" do
    test "returns only agents for the given initiative + dir", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      :ok = SessionStore.save("agent-2", "init-1", "/work/foo", "uuid-B", "claude", store)
      :ok = SessionStore.save("agent-3", "init-1", "/work/bar", "uuid-C", "claude", store)
      :ok = SessionStore.save("agent-4", "init-2", "/work/foo", "uuid-D", "claude", store)

      rows = SessionStore.list_by_dir("init-1", "/work/foo", store)
      assert length(rows) == 2
      assert {"agent-1", "uuid-A"} in rows
      assert {"agent-2", "uuid-B"} in rows
    end

    test "returns empty list when no sessions match", %{store: store} do
      assert [] = SessionStore.list_by_dir("init-x", "/no/such/dir", store)
    end
  end

  describe "delete_by_agent/2" do
    test "removes the row for the given agent", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      :ok = SessionStore.save("agent-2", "init-1", "/work/foo", "uuid-B", "claude", store)

      assert :ok = SessionStore.delete_by_agent("agent-1", store)
      assert {:error, :not_found} = SessionStore.get_by_agent("agent-1", store)
      assert {:ok, "uuid-B"} = SessionStore.get_by_agent("agent-2", store)
    end

    test "is a no-op for unknown agent", %{store: store} do
      assert :ok = SessionStore.delete_by_agent("ghost", store)
    end
  end

  describe "prune_deleted_initiatives/2" do
    test "removes sessions for initiatives not in the valid list", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      :ok = SessionStore.save("agent-2", "init-2", "/work/bar", "uuid-B", "claude", store)
      :ok = SessionStore.save("agent-3", "init-3", "/work/baz", "uuid-C", "claude", store)

      pruned = SessionStore.prune_deleted_initiatives(["init-1", "init-3"], store)
      assert pruned == 1

      assert {:ok, "uuid-A"} = SessionStore.get_by_agent("agent-1", store)
      assert {:error, :not_found} = SessionStore.get_by_agent("agent-2", store)
      assert {:ok, "uuid-C"} = SessionStore.get_by_agent("agent-3", store)
    end

    test "returns 0 when all initiatives are valid", %{store: store} do
      :ok = SessionStore.save("agent-1", "init-1", "/work/foo", "uuid-A", "claude", store)
      assert 0 = SessionStore.prune_deleted_initiatives(["init-1"], store)
    end

    test "returns 0 when table is empty", %{store: store} do
      assert 0 = SessionStore.prune_deleted_initiatives(["init-x"], store)
    end
  end

  describe "schema migration" do
    test "silently migrates old (initiative_id, dir) schema on startup", %{test: test} do
      db_path = Path.join(System.tmp_dir!(), "codrift_migrate_#{test}.db")
      on_exit(fn -> File.rm(db_path) end)

      # Seed old-schema DB directly via Exqlite
      {:ok, db} = Exqlite.Sqlite3.open(db_path)

      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE TABLE claude_sessions (
          initiative_id TEXT NOT NULL,
          dir           TEXT NOT NULL,
          session_id    TEXT NOT NULL,
          updated_at    TEXT NOT NULL,
          PRIMARY KEY (initiative_id, dir)
        )
        """)

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          db,
          "INSERT INTO claude_sessions VALUES (?1, ?2, ?3, ?4)"
        )

      :ok = Exqlite.Sqlite3.bind(stmt, ["init-old", "/old/dir", "old-uuid", "2024-01-01"])
      :done = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)
      Exqlite.Sqlite3.close(db)

      # Start SessionStore against that legacy DB — it should migrate without crash.
      # Use an explicit child spec to avoid ID conflict with the one from setup/1.
      name = :"session_store_migrate_#{test}"

      start_supervised!(%{
        id: name,
        start: {SessionStore, :start_link, [[path: db_path, name: name]]}
      })

      # Old data is gone (dropped), new schema works fine
      assert [] = SessionStore.list_all(name)

      assert :ok =
               SessionStore.save("new-agent", "init-1", "/work/x", "fresh-uuid", "claude", name)

      assert {:ok, "fresh-uuid"} = SessionStore.get_by_agent("new-agent", name)
    end
  end
end
