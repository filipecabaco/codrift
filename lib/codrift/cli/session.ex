defmodule Codrift.CLI.Session do
  @moduledoc """
  CLI implementation for session management commands.

  Opens `~/.codrift/codrift.db` directly — no GenServer required — so it
  works in the release `eval` context and when the TUI is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift session list
      codrift session list <initiative_id>
      codrift session prune
  """

  alias Codrift.Paths

  defp db_path, do: Path.join(Paths.data_dir(), "codrift.db")
  defp initiatives_path, do: Path.join(Paths.config_dir(), "initiatives.json")

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatches session CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["list" | rest]) do
    initiative_id = List.first(rest)
    ensure_exqlite()

    if db_missing?() do
      print_json(%{sessions: []})
    else
      with_db(fn db ->
        rows = list_sessions(db, initiative_id)

        sessions = Enum.map(rows, &row_to_session/1)

        print_json(%{sessions: sessions})
      end)
    end
  end

  def run(["prune" | _]) do
    ensure_exqlite()
    valid_ids = load_initiative_ids()

    if db_missing?() do
      print_json(%{pruned: 0})
    else
      with_db(fn db ->
        pruned = prune_sessions(db, valid_ids)
        print_json(%{pruned: pruned})
      end)
    end
  end

  def run(_) do
    IO.puts("""
    Usage:
      codrift session list [<initiative_id>]
      codrift session prune
    """)
  end

  # ── SQLite helpers ────────────────────────────────────────────────────────────

  defp db_missing?, do: not File.exists?(db_path())

  defp with_db(fun) do
    path = db_path()
    {:ok, db} = Exqlite.Sqlite3.open(path)

    try do
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp list_sessions(db, nil) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "SELECT agent_id, initiative_id, dir, session_id FROM claude_sessions"
      )

    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp list_sessions(db, initiative_id) do
    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(db, """
      SELECT agent_id, initiative_id, dir, session_id
      FROM claude_sessions
      WHERE initiative_id = ?1
      """)

    :ok = Exqlite.Sqlite3.bind(stmt, [initiative_id])
    rows = collect_rows(db, stmt, [])
    :ok = Exqlite.Sqlite3.release(db, stmt)
    rows
  end

  defp prune_sessions(db, valid_ids) do
    {:ok, id_stmt} =
      Exqlite.Sqlite3.prepare(db, "SELECT DISTINCT initiative_id FROM claude_sessions")

    all_ids = collect_scalar_rows(db, id_stmt, [])
    :ok = Exqlite.Sqlite3.release(db, id_stmt)
    stale_ids = Enum.reject(all_ids, &(&1 in valid_ids))

    Enum.each(stale_ids, fn initiative_id ->
      {:ok, del_stmt} =
        Exqlite.Sqlite3.prepare(db, "DELETE FROM claude_sessions WHERE initiative_id = ?1")

      :ok = Exqlite.Sqlite3.bind(del_stmt, [initiative_id])
      :done = Exqlite.Sqlite3.step(db, del_stmt)
      :ok = Exqlite.Sqlite3.release(db, del_stmt)
    end)

    length(stale_ids)
  end

  defp collect_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [agent_id, initiative_id, dir, session_id]} ->
        collect_rows(db, stmt, [{agent_id, initiative_id, dir, session_id} | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp collect_scalar_rows(db, stmt, acc) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, [value]} -> collect_scalar_rows(db, stmt, [value | acc])
      :done -> acc
    end
  end

  # ── Initiative JSON helpers ───────────────────────────────────────────────────

  defp load_initiative_ids do
    path = initiatives_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, %{"initiatives" => raw}} <- JSON.decode(content) do
      Map.keys(raw)
    else
      _ -> []
    end
  end

  defp ensure_exqlite do
    {:ok, _} = Application.ensure_all_started(:exqlite)
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))

  defp row_to_session({agent_id, init_id, dir, session_id}) do
    %{agent_id: agent_id, initiative_id: init_id, dir: dir, session_id: session_id}
  end
end
