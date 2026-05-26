defmodule Codrift.SessionStore do
  @moduledoc """
  Persists Claude Code session IDs to SQLite so sessions can be resumed
  across TUI restarts via `claude --resume <session-id>`.

  Table schema:
    claude_sessions (agent_id TEXT PRIMARY KEY, initiative_id TEXT, dir TEXT,
                     session_id TEXT, updated_at TEXT)

  Each agent gets its own row, allowing multiple Claude agents in the same
  directory to all resume independently on the next TUI launch.

  ## Migration

  If the database contains the old schema (keyed by `(initiative_id, dir)`
  with no `agent_id` column), the table is dropped and recreated on startup.
  Sessions are considered ephemeral enough that a one-time loss is acceptable.
  """

  use GenServer

  @default_path Path.expand("~/.codrift/codrift.db")

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Upserts a session ID keyed by agent ID."
  def save(agent_id, initiative_id, dir, session_id, server \\ __MODULE__) do
    GenServer.call(server, {:save, agent_id, initiative_id, dir, session_id})
  end

  @doc "Looks up a saved session ID by agent ID. Returns `{:ok, session_id}` or `{:error, :not_found}`."
  def get_by_agent(agent_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_by_agent, agent_id})
  end

  @doc "Returns all saved sessions as `[{agent_id, initiative_id, dir, session_id}]`."
  def list_all(server \\ __MODULE__) do
    GenServer.call(server, :list_all)
  end

  @doc "Returns all sessions for a given initiative + directory as `[{agent_id, session_id}]`."
  def list_by_dir(initiative_id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:list_by_dir, initiative_id, dir})
  end

  @doc "Deletes the session row for a specific agent ID."
  def delete_by_agent(agent_id, server \\ __MODULE__) do
    GenServer.call(server, {:delete_by_agent, agent_id})
  end

  @doc "Deletes all session rows whose initiative_id is not in `valid_ids`."
  def prune_deleted_initiatives(valid_ids, server \\ __MODULE__) do
    GenServer.call(server, {:prune_deleted_initiatives, valid_ids})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)

    path |> Path.dirname() |> File.mkdir_p!()

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok = migrate(db)

    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:save, agent_id, initiative_id, dir, session_id}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      INSERT OR REPLACE INTO claude_sessions (agent_id, initiative_id, dir, session_id, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """)

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id, initiative_id, dir, session_id, now])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)

    {:reply, :ok, state}
  end

  def handle_call({:get_by_agent, agent_id}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT session_id FROM claude_sessions WHERE agent_id = ?1
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id])

    result =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [session_id]} -> {:ok, session_id}
        :done -> {:error, :not_found}
      end

    :ok = Exqlite.Sqlite3.release(db, stmt)

    {:reply, result, state}
  end

  def handle_call(:list_all, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "SELECT agent_id, initiative_id, dir, session_id FROM claude_sessions"
      )

    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    {:reply, rows, state}
  end

  def handle_call({:list_by_dir, initiative_id, dir}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT agent_id, session_id FROM claude_sessions
      WHERE initiative_id = ?1 AND dir = ?2
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [initiative_id, dir])
    rows = collect_dir_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    {:reply, rows, state}
  end

  def handle_call({:delete_by_agent, agent_id}, _from, %{db: db} = state) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM claude_sessions WHERE agent_id = ?1")

    :ok = Exqlite.Sqlite3.bind(stmt, [agent_id])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    {:reply, :ok, state}
  end

  def handle_call({:prune_deleted_initiatives, valid_ids}, _from, %{db: db} = state) do
    rows = fetch_all_initiative_ids(db)
    stale = Enum.reject(rows, &(&1 in valid_ids))

    Enum.each(stale, fn initiative_id ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          db,
          "DELETE FROM claude_sessions WHERE initiative_id = ?1"
        )

      :ok = Exqlite.Sqlite3.bind(stmt, [initiative_id])
      :done = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)
    end)

    {:reply, length(stale), state}
  end

  defp fetch_all_initiative_ids(db) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, "SELECT DISTINCT initiative_id FROM claude_sessions")

    ids = collect_scalar_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    ids
  end

  defp collect_scalar_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [value]} -> collect_scalar_rows(db, stmt, [value | acc])
      :done -> acc
    end
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [agent_id, initiative_id, dir, session_id]} ->
        collect_rows(db, stmt, [{agent_id, initiative_id, dir, session_id} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp collect_dir_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [agent_id, session_id]} ->
        collect_dir_rows(db, stmt, [{agent_id, session_id} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  @impl true
  def terminate(_reason, %{db: db}) do
    Exqlite.Sqlite3.close(db)
  end

  # ── Schema migration ────────────────────────────────────────────────────────

  # If the old schema exists (PRIMARY KEY on (initiative_id, dir), no agent_id),
  # drop it and recreate. Sessions are ephemeral enough to lose once.
  defp migrate(db) do
    if needs_migration?(db) do
      :ok = Exqlite.Sqlite3.execute(db, "DROP TABLE IF EXISTS claude_sessions")
    end

    Exqlite.Sqlite3.execute(db, """
    CREATE TABLE IF NOT EXISTS claude_sessions (
      agent_id      TEXT PRIMARY KEY,
      initiative_id TEXT NOT NULL,
      dir           TEXT NOT NULL,
      session_id    TEXT NOT NULL,
      updated_at    TEXT NOT NULL
    )
    """)
  end

  defp needs_migration?(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "PRAGMA table_info(claude_sessions)")

    columns = collect_column_names(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)

    # Old schema has no agent_id column; new schema requires it.
    columns != [] and "agent_id" not in columns
  end

  defp collect_column_names(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      # PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
      {:row, [_cid, name | _rest]} ->
        collect_column_names(db, stmt, [name | acc])

      :done ->
        acc
    end
  end
end
