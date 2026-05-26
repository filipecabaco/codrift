defmodule Codrift.CLI.Memory do
  @moduledoc """
  CLI implementation for initiative memory store commands.

  Delegates to `Codrift.Memory` (pure module, opens its own DB connection).
  Works in the release `eval` context and when the TUI is not running.

  All output is JSON to stdout; errors go to stderr with a non-zero exit.

  ## Usage

      codrift memory search <initiative_id> <query>
      codrift memory add    <initiative_id> <type> <content>
      codrift memory add    <initiative_id> <type> <content> --source=<who>
      codrift memory delete <initiative_id> <id>
      codrift memory recent <initiative_id> [<limit>]
      codrift memory list   <initiative_id> <type>
      codrift memory stats  <initiative_id>

  Valid types: decision, summary, snippet, file_context, note
  """

  alias Codrift.Memory

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  @doc "Dispatches memory CLI subcommands from argv."
  @spec run([String.t()]) :: :ok
  def run(["search", initiative_id, query | _]) do
    ensure_exqlite()
    results = Memory.search(initiative_id, query)
    print_json(results)
  end

  def run(["add", initiative_id, chunk_type, content | rest]) do
    ensure_exqlite()
    validate_type!(chunk_type)
    source = parse_source(rest, "user")

    case Memory.add(initiative_id, chunk_type, content, source) do
      {:ok, id} -> print_json(%{id: id, chunk_type: chunk_type, source: source})
    end
  end

  def run(["delete", initiative_id, id_str | _]) do
    ensure_exqlite()
    rowid = parse_integer!(id_str, "id")

    case Memory.delete(initiative_id, rowid) do
      :ok -> print_json(%{deleted: rowid})
      {:error, :not_found} -> fail("entry not found: #{rowid}")
    end
  end

  def run(["recent", initiative_id | rest]) do
    ensure_exqlite()
    limit = parse_positive_integer(List.first(rest), 20)
    results = Memory.recent(initiative_id, limit)
    print_json(results)
  end

  def run(["list", initiative_id, chunk_type | _]) do
    ensure_exqlite()
    validate_type!(chunk_type)
    results = Memory.list(initiative_id, chunk_type)
    print_json(results)
  end

  def run(["stats", initiative_id | _]) do
    ensure_exqlite()
    result = Memory.stats(initiative_id)
    print_json(result)
  end

  def run(_) do
    types = Enum.join(Memory.valid_types(), ", ")

    IO.puts("""
    Usage:
      codrift memory search <initiative_id> <query>
      codrift memory add    <initiative_id> <type> <content> [--source=<who>]
      codrift memory delete <initiative_id> <id>
      codrift memory recent <initiative_id> [<limit>]
      codrift memory list   <initiative_id> <type>
      codrift memory stats  <initiative_id>

    Valid types: #{types}
    """)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp ensure_exqlite do
    {:ok, _} = Application.ensure_all_started(:exqlite)
  end

  defp validate_type!(chunk_type) do
    unless chunk_type in Memory.valid_types() do
      fail(
        "invalid type '#{chunk_type}'. Must be one of: #{Enum.join(Memory.valid_types(), ", ")}"
      )
    end
  end

  defp parse_source(args, default) do
    case Enum.find(args, &String.starts_with?(&1, "--source=")) do
      nil -> default
      flag -> String.slice(flag, 9..-1//1)
    end
  end

  defp parse_integer!(str, label) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> fail("invalid #{label}: #{inspect(str)}")
    end
  end

  defp parse_positive_integer(nil, default), do: default

  defp parse_positive_integer(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp print_json(data), do: IO.puts(JSON.encode!(data))

  @spec fail(String.t()) :: no_return()
  defp fail(msg) do
    IO.puts(:stderr, JSON.encode!(%{error: msg}))
    System.halt(1)
  end
end
