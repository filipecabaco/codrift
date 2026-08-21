defmodule Codrift.FreshnessTest do
  @moduledoc false
  # Registers in the global watcher registry, so it must not run alongside
  # anything else that broadcasts.
  use ExUnit.Case, async: false

  alias Codrift.{Freshness, Initiative, Memory}
  alias Codrift.Initiative.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    ctx = Path.join(tmp_dir, "ctx")
    File.mkdir_p!(ctx)
    json = Path.join(tmp_dir, "initiatives.json")

    store = start_supervised!({Store, path: json, name: nil, context_dir_base: ctx})

    # `interval: false` so nothing fires on a timer: every test below drives the
    # watcher with `poll/1` instead of sleeping out an interval.
    watcher = start_supervised!({Freshness, store: store, name: nil, interval: false})

    Registry.register(Codrift.AgentWatchers, :all, nil)

    {:ok, store: store, watcher: watcher, ctx: ctx, json: json}
  end

  # Writes initiatives.json the way the CLI does — behind the running store's
  # back, from what is a separate OS process in real use.
  defp write_externally!(json, initiatives) do
    data = Map.new(initiatives, fn i -> {i.id, Initiative.to_map(i)} end)
    File.write!(json, JSON.encode!(%{"initiatives" => data}))
  end

  describe "seeding" do
    test "the first pass announces nothing", %{watcher: watcher, store: store} do
      {:ok, _} = Store.create("Seeded", [], store)
      flush()

      :ok = Freshness.poll(watcher)

      refute_receive {:initiative_created, _}, 100
      refute_receive {:memory_changed, _}, 10
    end
  end

  describe "initiatives.json written by another process" do
    test "a new initiative reaches the store and the windows", %{
      watcher: watcher,
      store: store,
      json: json
    } do
      :ok = Freshness.poll(watcher)
      external = Initiative.new("From the CLI")
      write_externally!(json, [external])

      :ok = Freshness.poll(watcher)

      id = external.id
      assert_receive {:initiative_created, %Initiative{id: ^id, name: "From the CLI"}}
      # The point of reloading rather than only broadcasting: a running app that
      # announced the initiative but still served a list without it would answer
      # the very next `list_initiatives` with a lie.
      assert Enum.any?(Store.list(store), &(&1.id == id))
    end

    test "an edited initiative is an update, not a re-create", %{
      watcher: watcher,
      store: store,
      json: json
    } do
      {:ok, initiative} = Store.create("Before", [], store)
      :ok = Freshness.poll(watcher)
      flush()

      write_externally!(json, [%{initiative | name: "After"}])
      :ok = Freshness.poll(watcher)

      id = initiative.id
      assert_receive {:initiative_updated, %Initiative{id: ^id, name: "After"}}
      refute_receive {:initiative_created, _}, 50
      assert {:ok, %Initiative{name: "After"}} = Store.get(id, store)
    end

    test "an initiative missing from the file is announced as deleted", %{
      watcher: watcher,
      store: store,
      json: json
    } do
      {:ok, kept} = Store.create("Kept", [], store)
      {:ok, dropped} = Store.create("Dropped", [], store)
      :ok = Freshness.poll(watcher)
      flush()

      write_externally!(json, [kept])
      :ok = Freshness.poll(watcher)

      dropped_id = dropped.id
      assert_receive {:initiative_deleted, ^dropped_id}
      assert Enum.map(Store.list(store), & &1.id) == [kept.id]
    end

    test "an unchanged file announces nothing", %{watcher: watcher, store: store} do
      {:ok, _} = Store.create("Quiet", [], store)
      :ok = Freshness.poll(watcher)
      flush()

      :ok = Freshness.poll(watcher)
      :ok = Freshness.poll(watcher)

      refute_receive {:initiative_updated, _}, 100
    end

    # A truncated or half-written file yields no initiatives, which is
    # indistinguishable from every initiative having been deleted. Acting on it
    # would broadcast a delete for each and drop them from the running store.
    test "an unreadable file changes nothing", %{watcher: watcher, store: store, json: json} do
      {:ok, initiative} = Store.create("Survivor", [], store)
      :ok = Freshness.poll(watcher)
      flush()

      File.write!(json, "{ this is not json")
      :ok = Freshness.poll(watcher)

      refute_receive {:initiative_deleted, _}, 100
      assert Enum.map(Store.list(store), & &1.id) == [initiative.id]
    end
  end

  describe "memory written by another process" do
    test "a new entry announces the initiative whose store moved", %{
      watcher: watcher,
      store: store,
      ctx: ctx
    } do
      {:ok, initiative} = Store.create("With memory", [], store)
      :ok = Freshness.poll(watcher)
      flush()

      # Written straight to the file the way `codrift memory add` does, then
      # touched, since two writes inside one second can share an mtime.
      write_memory!(ctx, initiative.id)
      :ok = Freshness.poll(watcher)

      id = initiative.id
      assert_receive {:memory_changed, ^id}
    end

    test "an untouched memory store stays quiet", %{
      watcher: watcher,
      store: store,
      ctx: ctx
    } do
      {:ok, initiative} = Store.create("Idle memory", [], store)
      write_memory!(ctx, initiative.id)
      :ok = Freshness.poll(watcher)
      flush()

      :ok = Freshness.poll(watcher)

      refute_receive {:memory_changed, _}, 100
    end
  end

  defp write_memory!(ctx, id) do
    path = Path.join([ctx, id, Memory.db_file()])
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE VIRTUAL TABLE IF NOT EXISTS memory USING fts5(chunk_type, content, source)
      """)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "INSERT INTO memory (chunk_type, content, source) VALUES ('note', 'hi', 'cli')"
      )

    :ok = Exqlite.Sqlite3.close(db)
  end

  # The store broadcasts on its own writes too, so setup leaves events in the
  # mailbox that have nothing to do with what a test is asserting.
  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
