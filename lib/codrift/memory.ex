defmodule Codrift.Memory do
  @moduledoc """
  Shared, searchable knowledge base for an initiative.

  Each initiative gets a dedicated SQLite database at
  `~/.codrift/initiatives/{id}/memory.db` using SQLite's built-in FTS5
  extension — no extra dependencies, no embeddings.

  ## How retrieval works

  Every initiative brief tells agents to search this store before starting
  work, so the queries that arrive are questions — "does a sprite sleep while
  an agent is working" — not keywords. Two things make that answerable:

    * **Terms are OR-joined, and stopwords are dropped.** FTS5 reads a space
      between terms as `AND`, so an eight-word question used to demand all
      eight tokens appear in one entry. Measured over 34 hand-labelled
      questions against two real stores, *every one* returned nothing. The
      point of BM25 is to rank a broad match, not to filter a narrow one.
    * **Chunks are indexed, entries are returned.** BM25 divides by document
      length and real entries run 0.6–2.7 kB, so `Codrift.Memory.Chunker`
      splits them and search collapses matching chunks back to their parent
      entry, best-ranked chunk first.

  `mix codrift.memory.eval` is the regression gate for both.

  Terms are *not* silently turned into prefix queries: measured, that lowered
  MRR from 0.87 to 0.85 by broadening the match set and diluting the ranking.
  A trailing `*` a caller types is still honoured.

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

  alias Codrift.Memory.Chunker
  alias Codrift.Web.EventRelay

  @db_file "memory.db"
  @valid_types ~w(decision summary snippet file_context note)

  @doc "Returns the filesystem path to the memory DB for an initiative."
  @spec db_path(String.t()) :: String.t()
  def db_path(initiative_id),
    do: Path.join(Codrift.Paths.initiative_dir(initiative_id), @db_file)

  @doc """
  The DB file name inside an initiative's context folder.

  Exposed for `Codrift.Freshness`, which resolves the file against the base
  directory its store reports rather than the global one.
  """
  @spec db_file() :: String.t()
  def db_file, do: @db_file

  @doc "Returns the list of valid chunk type strings."
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

  @doc """
  Full-text searches all memory entries for an initiative.

  Plain words are OR-joined and English stopwords dropped, so a whole question
  works as a query. Quoted phrases match as phrases, explicit `AND`/`OR`/`NOT`
  are preserved, and a trailing `*` makes a term a prefix.

  Returns up to 20 entries ordered by relevance (best match first).
  `rank` is a negative BM25 score; closer to 0 means more relevant — it is the
  rank of the entry's best-matching chunk, so callers can threshold on it.

      iex> Codrift.Memory.search("init1", "why did we pick JWT over sessions")
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
    case to_match_expr(query) do
      "" ->
        []

      match ->
        with_db(initiative_id, fn db ->
          backfill_chunks(db)

          db
          |> ranked_parents(match)
          |> fetch_entries(db)
        end)
    end
  end

  # Chunks are ranked, entries are returned. Over-fetching before the dedupe is
  # what makes that honest: several chunks of one long entry can outrank every
  # chunk of the next entry, so taking 20 chunks could collapse to two results.
  @chunk_fetch 200
  @result_limit 20

  defp ranked_parents(db, match) do
    db
    |> query(
      """
      SELECT parent_id, rank FROM memory_chunks
      WHERE memory_chunks MATCH ?1 ORDER BY rank LIMIT #{@chunk_fetch}
      """,
      [match],
      fn [parent_id, rank] -> {parent_id, rank} end
    )
    # Ordered by rank already, so the first chunk seen for an entry is its best.
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(@result_limit)
  end

  defp fetch_entries([], _db), do: []

  defp fetch_entries(ranked, db) do
    ids = Enum.map(ranked, &elem(&1, 0))
    placeholders = Enum.map_join(1..length(ids), ",", &"?#{&1}")

    rows =
      query(
        db,
        "SELECT rowid, chunk_type, content, source FROM memory WHERE rowid IN (#{placeholders})",
        ids,
        &row_to_map/1
      )

    by_id = Map.new(rows, &{&1.id, &1})

    # Re-ordered by chunk rank: `IN` returns rows in rowid order, which is
    # insertion order, which is not relevance.
    for {id, rank} <- ranked, entry = by_id[id], do: Map.put(entry, :rank, rank)
  end

  # FTS5 treats `(`, `)`, `*`, `:` and `"` as operators, so a literal query like
  # `greet()` is a syntax error. Quoting every bare term is what makes such a
  # query safe, and it stays — the bug was never the quoting, it was joining the
  # quoted terms with a space, which FTS5 reads as AND.
  @fts_operators ~w(AND OR NOT)

  # Words that carry no retrieval signal but, under an implicit AND, each
  # demanded a row contain them: "does a sprite sleep while an agent is working"
  # has four content words in nine.
  @stopwords MapSet.new(~w(
    a an the and or but if is are was were be been being do does did doing
    have has had having i we you he she it its they them our your their
    this that these those to of in on at by for with about into over
    after before while when where why how what which who whom whose
    there here not no so than then too very can could should would will
    shall may might must am as from up down out off again further once
    any all some own same now get got make made use used using
  ))

  defp to_match_expr(query) when is_binary(query) do
    tokens = tokens(query)
    # A question made entirely of stopwords means them literally — "how to" is a
    # real thing to look for, and answering it with nothing is the failure this
    # whole path exists to fix.
    kept = with [] <- drop_stopwords(tokens), do: tokens

    kept |> sanitize_operators() |> join()
  end

  defp to_match_expr(_), do: ""

  defp tokens(query) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(query)
    |> Enum.map(&classify/1)
    |> Enum.reject(&(&1 == :skip))
  end

  # An unmatched capture group comes back as "". Quoted input stays a `:phrase`
  # and bare input a `:term`, because the two are treated differently from here:
  # only a bare term is a stopword candidate, and only a bare term can carry a
  # prefix `*`.
  defp classify([_, phrase]), do: phrase_or_skip(phrase)

  defp classify([_, "", token]),
    do: if(token in @fts_operators, do: {:op, token}, else: {:term, token})

  defp classify([_, phrase, _]), do: phrase_or_skip(phrase)

  defp phrase_or_skip(text), do: if(String.trim(text) == "", do: :skip, else: {:phrase, text})

  defp drop_stopwords(tokens) do
    Enum.reject(tokens, fn
      {:term, t} -> MapSet.member?(@stopwords, String.downcase(t))
      _ -> false
    end)
  end

  # Every position FTS5 cannot parse an operator in: leading, trailing, or
  # adjacent to another. Dropping a stopword between two operators produces the
  # last of those, so all three are one pass.
  defp sanitize_operators(tokens) do
    tokens
    |> Enum.reduce([], fn
      {:op, _}, [] -> []
      {:op, _}, [{:op, _} | _] = acc -> acc
      token, acc -> [token | acc]
    end)
    |> Enum.drop_while(&match?({:op, _}, &1))
    |> Enum.reverse()
  end

  # OR between terms the caller merely listed; operators they typed themselves
  # are left to mean what they say.
  defp join([]), do: ""
  defp join([token]), do: render(token)
  defp join([{:op, op} | rest]), do: op <> " " <> join(rest)
  defp join([token, {:op, _} = op | rest]), do: render(token) <> " " <> join([op | rest])
  defp join([token | rest]), do: render(token) <> " OR " <> join(rest)

  defp render({:phrase, text}), do: quoted(text)

  defp render({:term, text}) do
    # `"foo*"` is not a prefix query — FTS5 tokenizes the `*` away inside the
    # quotes. Outside them it is, so a trailing `*` has to survive the quoting
    # rather than be swallowed by it.
    case String.split_at(text, -1) do
      {stem, "*"} when stem != "" -> quoted(stem) <> "*"
      _ -> quoted(text)
    end
  end

  defp quoted(text), do: ~s("#{String.replace(text, ~s("), ~s(""))}")

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
    result =
      with_db(initiative_id, fn db ->
        exec(db, "INSERT INTO memory (chunk_type, content, source) VALUES (?1, ?2, ?3)", [
          chunk_type,
          content,
          source
        ])

        rowid = last_insert_rowid(db)
        index_chunks(db, rowid, content)
        {:ok, rowid}
      end)

    notify_changed(initiative_id)
    result
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
        exec(db, "DELETE FROM memory WHERE rowid = ?1", [rowid])
        delete_chunks(db, rowid)
        :ok
      else
        {:error, :not_found}
      end
    end)
    |> tap(fn
      :ok -> notify_changed(initiative_id)
      {:error, :not_found} -> :ok
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

  # Tells open windows the store moved, so an entry an agent just wrote shows up
  # without a reload. Only *that* it changed: the memory view owns a query string
  # no event could reproduce, so the only correct refresh is it re-running its
  # own query.
  #
  # Keeping this module pure and process-free is the constraint everything else
  # here bends around, and this respects it — `broadcast/1` is a `Registry`
  # dispatch that no-ops when there is no registry, which is exactly the truth in
  # `eval` context: nobody is watching. A CLI write reaches open windows through
  # `Codrift.Freshness` instead.
  defp notify_changed(initiative_id) do
    EventRelay.broadcast({:memory_changed, initiative_id})
  end

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

    # Derived from `memory`, never authoritative: `memory` remains the store of
    # record and is not migrated, so an existing hand-curated database gains an
    # index and risks nothing. `parent_id` is UNINDEXED because it is a join key,
    # not something to full-text search.
    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunks USING fts5(
        content,
        parent_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
      """)
  end

  defp index_chunks(db, rowid, content) do
    for chunk <- Chunker.split(content) do
      exec(db, "INSERT INTO memory_chunks (content, parent_id) VALUES (?1, ?2)", [chunk, rowid])
    end

    :ok
  end

  defp delete_chunks(db, rowid) do
    exec(db, "DELETE FROM memory_chunks WHERE CAST(parent_id AS INTEGER) = ?1", [rowid])
  end

  # Indexes whatever is in `memory` but not yet in `memory_chunks`.
  #
  # Chunking arrived after entries did, and `codrift memory add` from an older
  # binary can still write an unchunked row, so the read path repairs rather
  # than assuming. It is idempotent and cannot lose anything: chunks are derived
  # data, rebuilt from the entry they came from.
  #
  defp backfill_chunks(db) do
    db
    |> query(
      """
      SELECT rowid, content FROM memory
      WHERE rowid NOT IN (SELECT CAST(parent_id AS INTEGER) FROM memory_chunks)
      """,
      [],
      & &1
    )
    |> Enum.each(fn [rowid, content] -> index_chunks(db, rowid, content) end)
  end

  defp last_insert_rowid(db), do: scalar(db, "SELECT last_insert_rowid()")

  defp count_all(db), do: scalar(db, "SELECT COUNT(*) FROM memory")

  defp count_by_type(db) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT chunk_type, COUNT(*) FROM memory GROUP BY chunk_type
      """)

    rows = collect_rows(db, stmt, fn [type, count] -> {type, count} end, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    Map.new(rows)
  end

  # Every read in this module was the same four lines around collect_rows/4.
  defp query(db, sql, params, mapper) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = collect_rows(db, stmt, mapper, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp scalar(db, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    {:row, [value]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    value
  end

  defp exec(db, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok
  end

  defp collect_rows(db, stmt, mapper, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} ->
        collect_rows(db, stmt, mapper, [mapper.(row) | acc])

      :done ->
        Enum.reverse(acc)

      {:error, reason} ->
        require Logger
        Logger.warning("memory query failed: #{inspect(reason)}")
        Enum.reverse(acc)
    end
  end

  defp row_to_map([rowid, chunk_type, content, source]) do
    %{id: rowid, chunk_type: chunk_type, content: content, source: source}
  end
end
