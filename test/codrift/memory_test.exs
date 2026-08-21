defmodule Codrift.MemoryTest do
  use ExUnit.Case, async: true

  alias Codrift.Memory

  setup do
    id = "mem-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Codrift.Paths.initiative_dir(id)) end)
    {:ok, id: id}
  end

  defp seed!(id, entries) do
    for {type, content} <- entries do
      {:ok, rowid} = Memory.add(id, type, content, "test")
      rowid
    end
  end

  describe "search/2 query handling" do
    setup %{id: id} do
      seed!(id, [
        {"decision", "Checkout uses Stripe PaymentIntents, not Charges"},
        {"summary", "Migrated greet() to template literals"},
        {"snippet", "git worktree add ../wt codrift/checkout"}
      ])

      :ok
    end

    test "finds entries by a plain word", %{id: id} do
      assert [%{content: content}] = Memory.search(id, "Stripe")
      assert content =~ "Stripe"
    end

    # FTS5 reads `(`, `)` and `*` as operators.
    test "treats code punctuation as literal text, not FTS5 syntax", %{id: id} do
      assert [%{content: content}] = Memory.search(id, "greet()")
      assert content =~ "greet()"
    end

    test "does not raise on queries made only of operators or punctuation", %{id: id} do
      for query <- [")", "(", "\"", "*", "AND", "NOT OR", "  ", ""] do
        assert is_list(Memory.search(id, query)), "search crashed on #{inspect(query)}"
      end
    end

    test "supports a quoted phrase", %{id: id} do
      assert [%{content: content}] = Memory.search(id, ~s("template literals"))
      assert content =~ "template literals"
    end

    test "keeps boolean operators between terms", %{id: id} do
      assert [_] = Memory.search(id, "Stripe AND Charges")
      assert [] = Memory.search(id, "Stripe AND nonexistentword")
    end

    test "ignores a dangling operator instead of erroring", %{id: id} do
      assert [%{content: content}] = Memory.search(id, "Stripe AND")
      assert content =~ "Stripe"
    end

    test "matches a path-like term containing slashes", %{id: id} do
      assert [%{content: content}] = Memory.search(id, "codrift/checkout")
      assert content =~ "codrift/checkout"
    end

    test "returns [] for a term that is absent", %{id: id} do
      assert [] = Memory.search(id, "kubernetes")
    end
  end

  # The failure this whole path exists to fix: a question-shaped query used to
  # return nothing at all, because FTS5 reads a space between terms as AND and an
  # eight-word question then demanded all eight tokens appear in one entry.
  describe "search/2 with natural-language questions" do
    setup %{id: id} do
      seed!(id, [
        {"decision",
         "A Sprite keeps its keepalive open for as long as any agent process is " <>
           "alive, so a workspace never suspends while an agent is still working."},
        {"note",
         "Notarization is a launch dependency, not a caveat: the install path " <>
           "shows an OS warning at exactly the moment we ask for trust."},
        {"snippet", "git worktree add ../wt codrift/checkout"}
      ])

      :ok
    end

    test "answers a whole question rather than returning nothing", %{id: id} do
      assert [%{content: content} | _] =
               Memory.search(id, "does a sprite sleep while an agent is working")

      assert content =~ "keepalive"
    end

    test "a term the entry does not contain no longer excludes it", %{id: id} do
      # Under the old implicit AND this was empty: no entry holds both words.
      assert [_ | _] = Memory.search(id, "sprite unicorn")
    end

    test "ranks the entry that matches more terms first", %{id: id} do
      assert [%{content: first} | _] = Memory.search(id, "keepalive agent workspace")
      assert first =~ "keepalive"
    end

    # Dropping stopwords is what makes questions work, but a query that is only
    # stopwords still means them: answering "how to" with nothing is the same
    # silent failure in a smaller costume.
    test "falls back to the literal terms when a query is all stopwords", %{id: id} do
      assert [_ | _] = Memory.search(id, "for as long as")
    end

    test "an explicit AND still narrows", %{id: id} do
      assert [_] = Memory.search(id, "keepalive AND agent")
      assert [] = Memory.search(id, "keepalive AND nonexistentword")
    end

    # `"term*"` is not a prefix query — FTS5 tokenizes the star away inside the
    # quotes — so the star has to survive outside them. The token is deliberately
    # nonsense: a real word would be stemmed, and stemming would match the short
    # form whether or not prefixing worked, proving nothing either way.
    #
    # The negative half matters just as much: prefixing every term was measured
    # to drop MRR from 0.87 to 0.85, so it happens only when asked for.
    test "treats a trailing star as a prefix, and nothing else", %{id: id} do
      seed!(id, [{"note", "The rollback token lives in zzyxqualifier storage."}])

      assert [%{content: content}] = Memory.search(id, "zzyx*")
      assert content =~ "zzyxqualifier"
      assert [] = Memory.search(id, "zzyx")
    end
  end

  describe "search/2 over chunked entries" do
    # Long entries are the reason chunking exists: BM25 divides by document
    # length, so before chunking a 2 kB entry mentioning a term once lost to a
    # short one that did.
    test "finds a term buried deep inside a long entry", %{id: id} do
      filler = String.duplicate("unrelated background prose. ", 120)
      seed!(id, [{"note", filler <> " The rollback token is stored in vault_seven."}])

      assert [%{content: content}] = Memory.search(id, "where is the rollback token stored")
      assert content =~ "vault_seven"
    end

    test "returns each entry once however many of its chunks match", %{id: id} do
      repeated = String.duplicate("keepalive keepalive keepalive filler text. ", 60)
      seed!(id, [{"note", repeated}])

      results = Memory.search(id, "keepalive")
      assert length(results) == length(Enum.uniq_by(results, & &1.id))
    end

    test "returns the whole entry, not the chunk that matched", %{id: id} do
      long = String.duplicate("paragraph of context. ", 100) <> " sentinel_marker"
      seed!(id, [{"note", long}])

      assert [%{content: content}] = Memory.search(id, "sentinel_marker")
      assert content == long
    end

    test "deleting an entry removes it from the index too", %{id: id} do
      [rowid] = seed!(id, [{"note", String.duplicate("disposable content here. ", 60)}])
      assert [_] = Memory.search(id, "disposable")

      :ok = Memory.delete(id, rowid)

      assert [] = Memory.search(id, "disposable")
    end
  end

  # Chunking arrived after entries did, and `codrift memory add` from an older
  # binary can still write an unchunked row. The read path repairs rather than
  # assuming — and must never touch the entries themselves, since at least one
  # real store in the wild was curated by hand.
  describe "backfilling a store written before chunking" do
    setup %{id: id} do
      path = Memory.db_path(id)
      path |> Path.dirname() |> File.mkdir_p!()
      {:ok, db} = Exqlite.Sqlite3.open(path)

      :ok =
        Exqlite.Sqlite3.execute(db, """
        CREATE VIRTUAL TABLE memory USING fts5(
          chunk_type, content, source, tokenize = 'porter unicode61'
        )
        """)

      :ok =
        Exqlite.Sqlite3.execute(db, """
        INSERT INTO memory (chunk_type, content, source)
        VALUES ('decision', 'Hand curated entry about vault_seven and rollbacks', 'human')
        """)

      :ok = Exqlite.Sqlite3.close(db)
      :ok
    end

    test "an entry written before the chunk table existed is searchable", %{id: id} do
      assert [%{content: content}] = Memory.search(id, "what do we know about vault_seven")
      assert content =~ "vault_seven"
    end

    test "the entry itself is left exactly as it was", %{id: id} do
      before = Memory.recent(id, 10)
      _ = Memory.search(id, "vault_seven")

      assert Memory.recent(id, 10) == before
    end

    test "is idempotent — a second search does not re-index", %{id: id} do
      _ = Memory.search(id, "vault_seven")
      first = chunk_count(id)
      _ = Memory.search(id, "rollbacks")

      assert chunk_count(id) == first
    end
  end

  defp chunk_count(id) do
    {:ok, db} = Exqlite.Sqlite3.open(Memory.db_path(id))
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT count(*) FROM memory_chunks")
    {:row, [n]} = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.release(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)
    n
  end

  # An agent writing over MCP shares this VM with the open window, so it can be
  # told directly; a `codrift memory add` in a shell cannot, and reaches the
  # window through Codrift.Freshness instead. Ids are pinned because the watcher
  # registry is global and other async tests broadcast into the same mailbox.
  describe "change notification" do
    setup do
      Registry.register(Codrift.AgentWatchers, :all, nil)
      :ok
    end

    test "add announces the initiative whose store moved", %{id: id} do
      {:ok, _} = Memory.add(id, "note", "something worth keeping", "agent-x")

      assert_receive {:memory_changed, ^id}
    end

    test "delete announces too", %{id: id} do
      {:ok, rowid} = Memory.add(id, "note", "temporary", "agent-x")
      assert_receive {:memory_changed, ^id}

      :ok = Memory.delete(id, rowid)

      assert_receive {:memory_changed, ^id}
    end

    # Nothing changed, so there is nothing to announce — a window that re-queried
    # here would be re-querying for no reason.
    test "a delete that found nothing stays quiet", %{id: id} do
      {:ok, _} = Memory.add(id, "note", "kept", "agent-x")
      assert_receive {:memory_changed, ^id}

      assert {:error, :not_found} = Memory.delete(id, 9999)

      refute_receive {:memory_changed, ^id}, 100
    end
  end
end
