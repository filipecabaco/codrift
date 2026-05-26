defmodule Codrift.SessionStore do
  @moduledoc """
  Persists Claude Code session IDs to SQLite so sessions can be resumed
  across TUI restarts via `claude --resume <session-id>`.

  Table schema:
    claude_sessions (initiative_id TEXT, dir TEXT, session_id TEXT, updated_at TEXT,
                     PRIMARY KEY (initiative_id, dir))
  """

  use GenServer

  @default_path Path.expand("~/.codrift/codrift.db")

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Upserts a session ID for the given initiative + directory pair."
  def save(initiative_id, dir, session_id, server \\ __MODULE__) do
    GenServer.call(server, {:save, initiative_id, dir, session_id})
  end

  @doc "Looks up a saved session ID. Returns `{:ok, session_id}` or `{:error, :not_found}`."
  def get(initiative_id, dir, server \\ __MODULE__) do
    GenServer.call(server, {:get, initiative_id, dir})
  end

  @doc "Returns all saved sessions as `[{initiative_id, dir, session_id}]`."
  def list_all(server \\ __MODULE__) do
    GenServer.call(server, :list_all)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)

    # Ensure the directory exists
    path |> Path.dirname() |> File.mkdir_p!()

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS claude_sessions (
        initiative_id TEXT NOT NULL,
        dir TEXT NOT NULL,
        session_id TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (initiative_id, dir)
      )
      """)

    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:save, initiative_id, dir, session_id}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      INSERT OR REPLACE INTO claude_sessions (initiative_id, dir, session_id, updated_at)
      VALUES (?1, ?2, ?3, ?4)
      """)

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    :ok = Exqlite.Sqlite3.bind(stmt, [initiative_id, dir, session_id, now])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)

    {:reply, :ok, state}
  end

  def handle_call({:get, initiative_id, dir}, _from, %{db: db} = state) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT session_id FROM claude_sessions WHERE initiative_id = ?1 AND dir = ?2
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [initiative_id, dir])

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
      Exqlite.Sqlite3.prepare(db, "SELECT initiative_id, dir, session_id FROM claude_sessions")

    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    {:reply, rows, state}
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [initiative_id, dir, session_id]} ->
        collect_rows(db, stmt, [{initiative_id, dir, session_id} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  @impl true
  def terminate(_reason, %{db: db}) do
    Exqlite.Sqlite3.close(db)
  end
end
