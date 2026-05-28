defmodule Codrift.Memory do
  @moduledoc """
  Shared, searchable knowledge base for an initiative.

  Each initiative gets a dedicated SQLite database at
  `~/.codrift/initiatives/{id}/memory.db` using SQLite's built-in FTS5
  extension — no extra dependencies, no embeddings.

  This is a **pure module** with no supervised process. It opens and closes
  its own DB connection on every call, making it safe for use in `eval`
  context (release CLI), inside GenServers, and in tests.

  ## chunk_type vocabulary

  Agents must use one of these string types:

  | Type          | When to use                                               |
  |---------------|-----------------------------------------------------------|
  | `decision`    | Architectural or design choices made during this initiative |
  | `summary`     | Completion summary after finishing a task or subtask      |
  | `snippet`     | Reusable code pattern or config fragment                  |
  | `file_context`| What a key file does and why — saves re-reading next session |
  | `note`        | Free-form observation that doesn't fit another type       |

  ## Usage

      Codrift.Memory.search("abc123", "authentication middleware")
      # => [%{id: 7, chunk_type: "decision", content: "...", source: "agent-x", rank: -1.2}]

      {:ok, id} = Codrift.Memory.add("abc123", "decision", "Use JWT", "agent-x")
      Codrift.Memory.delete("abc123", id)
      Codrift.Memory.recent("abc123", 10)
      Codrift.Memory.list("abc123", "decision")
      Codrift.Memory.stats("abc123")
  """

  @db_file "memory.db"
  @valid_types ~w(decision summary snippet file_context note)

  @doc "Returns the filesystem path to the memory DB for an initiative."
  @spec db_path(String.t()) :: String.t()
  def db_path(initiative_id),
    do: Path.expand("~/.codrift/initiatives/#{initiative_id}/#{@db_file}")

  @doc "Returns the list of valid chunk type strings."
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

  @doc """
  Full-text searches all memory entries for an initiative.

  The `query` string uses SQLite FTS5 MATCH syntax — plain words, phrases in
  quotes, and `AND`/`OR`/`NOT` operators are supported.

  Returns up to 20 results ordered by relevance (best match first).
  `rank` is a negative BM25 score; closer to 0 means more relevant.

      iex> Codrift.Memory.search("init1", "JWT authentication")
      [%{id: 3, chunk_type: "decision", content: "Use JWT, not sessions",
         source: "agent-abc", rank: -1.5}]
  """
  @spec search(String.t(), String.t()) ::
          [
            %{
              id: integer(),
              chunk_type: String.t(),
              content: String.t(),
              source: String.t(),
              rank: float()
            }
          ]
  def search(initiative_id, query) do
    with_db(initiative_id, fn db ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, """
        SELECT rowid, chunk_type, content, source, rank
        FROM memory
        WHERE memory MATCH ?1
        ORDER BY rank
        LIMIT 20
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [query])
      rows = collect_rows(db, stmt, &search_row_to_map/1, [])
      :ok = Exqlite.Sqlite3.release(db, stmt)
      rows
    end)
  end

  @doc """
  Stores a new memory entry for an initiative.

  Returns `{:ok, rowid}` where `rowid` is the stable handle for deletion.
  `source` defaults to `"user"` when not provided.

      iex> {:ok, id} = Codrift.Memory.add("init1", "decision", "Use JWT", "agent-abc")
      iex> is_integer(id)
      true
  """
  @spec add(String.t(), String.t(), String.t(), String.t()) :: {:ok, integer()}
  def add(initiative_id, chunk_type, content, source \\ "user") do
    with_db(initiative_id, fn db ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, """
        INSERT INTO memory (chunk_type, content, source) VALUES (?1, ?2, ?3)
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [chunk_type, content, source])
      :done = Exqlite.Sqlite3.step(db, stmt)
      :ok = Exqlite.Sqlite3.release(db, stmt)

      {:ok, last_insert_rowid(db)}
    end)
  end

  @doc """
  Deletes a memory entry by its rowid.

  Returns `:ok` on success, `{:error, :not_found}` when no row has that id.

      iex> Codrift.Memory.delete("init1", 999)
      {:error, :not_found}
  """
  @spec delete(String.t(), integer()) :: :ok | {:error, :not_found}
  def delete(initiative_id, rowid) do
    with_db(initiative_id, fn db ->
      {:ok, exists_stmt} =
        Exqlite.Sqlite3.prepare(db, "SELECT rowid FROM memory WHERE rowid = ?1")

      :ok = Exqlite.Sqlite3.bind(exists_stmt, [rowid])
      found = Exqlite.Sqlite3.step(db, exists_stmt) != :done
      :ok = Exqlite.Sqlite3.release(db, exists_stmt)

      if found do
        {:ok, del_stmt} = Exqlite.Sqlite3.prepare(db, "DELETE FROM memory WHERE rowid = ?1")

        :ok = Exqlite.Sqlite3.bind(del_stmt, [rowid])
        :done = Exqlite.Sqlite3.step(db, del_stmt)
        :ok = Exqlite.Sqlite3.release(db, del_stmt)
        :ok
      else
        {:error, :not_found}
      end
    end)
  end

  @doc """
  Returns the most recent `limit` entries across all types, newest first.

  `limit` defaults to 20.

      iex> Codrift.Memory.recent("init1", 5)
      [%{id: 10, chunk_type: "summary", content: "...", source: "agent-abc"}, ...]
  """
  @spec recent(String.t(), pos_integer()) ::
          [%{id: integer(), chunk_type: String.t(), content: String.t(), source: String.t()}]
  def recent(initiative_id, limit \\ 20) do
    with_db(initiative_id, fn db ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, """
        SELECT rowid, chunk_type, content, source
        FROM memory
        ORDER BY rowid DESC
        LIMIT ?1
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [limit])
      rows = collect_rows(db, stmt, &row_to_map/1, [])
      :ok = Exqlite.Sqlite3.release(db, stmt)
      rows
    end)
  end

  @doc """
  Returns all entries of a specific chunk_type, newest first.

      iex> Codrift.Memory.list("init1", "decision")
      [%{id: 3, chunk_type: "decision", content: "...", source: "agent-abc"}, ...]
  """
  @spec list(String.t(), String.t()) ::
          [%{id: integer(), chunk_type: String.t(), content: String.t(), source: String.t()}]
  def list(initiative_id, chunk_type) do
    with_db(initiative_id, fn db ->
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, """
        SELECT rowid, chunk_type, content, source
        FROM memory
        WHERE chunk_type = ?1
        ORDER BY rowid DESC
        """)

      :ok = Exqlite.Sqlite3.bind(stmt, [chunk_type])
      rows = collect_rows(db, stmt, &row_to_map/1, [])
      :ok = Exqlite.Sqlite3.release(db, stmt)
      rows
    end)
  end

  @doc """
  Returns total entry count and a breakdown by chunk_type.

      iex> Codrift.Memory.stats("init1")
      %{total: 10, by_type: %{"decision" => 3, "snippet" => 7}}
  """
  @spec stats(String.t()) :: %{total: integer(), by_type: %{String.t() => integer()}}
  def stats(initiative_id) do
    with_db(initiative_id, fn db ->
      total = count_all(db)
      by_type = count_by_type(db)
      %{total: total, by_type: by_type}
    end)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp with_db(initiative_id, fun) do
    path = db_path(initiative_id)
    path |> Path.dirname() |> File.mkdir_p!()
    {:ok, db} = Exqlite.Sqlite3.open(path)
    ensure_schema(db)

    try do
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp ensure_schema(db) do
    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE VIRTUAL TABLE IF NOT EXISTS memory USING fts5(
        chunk_type,
        content,
        source,
        tokenize = 'porter unicode61'
      )
      """)
  end

  defp last_insert_rowid(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT last_insert_rowid()")
    {:row, [rowid]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rowid
  end

  defp count_all(db) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM memory")
    {:row, [count]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    count
  end

  defp count_by_type(db) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT chunk_type, COUNT(*) FROM memory GROUP BY chunk_type
      """)

    rows = collect_rows(db, stmt, fn [type, count] -> {type, count} end, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Map.new(rows)
  end

  defp collect_rows(db, stmt, mapper, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> collect_rows(db, stmt, mapper, [mapper.(row) | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp search_row_to_map([rowid, chunk_type, content, source, rank]) do
    %{id: rowid, chunk_type: chunk_type, content: content, source: source, rank: rank}
  end

  defp row_to_map([rowid, chunk_type, content, source]) do
    %{id: rowid, chunk_type: chunk_type, content: content, source: source}
  end
end
