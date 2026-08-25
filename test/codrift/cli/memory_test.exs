defmodule Codrift.CLI.MemoryTest do
  @moduledoc """
  Coverage for `codrift memory`, the CLI half of the shared memory store.

  This is the surface agents that cannot reach MCP use, and its whole contract
  is *one JSON document on stdout* — an agent parses it, so a stray log line or
  a changed key breaks the caller silently rather than loudly. That is what is
  asserted here: not that the store works (`Codrift.MemoryTest` covers that),
  but that the command speaks JSON and honours its flags.

  The `fail/1` paths are deliberately not exercised: they call `System.halt/1`,
  which would take the test VM with them — the same reason the other CLI suites
  only drive their non-halting paths.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Codrift.CLI.Memory, as: CLI
  alias Codrift.Memory

  setup do
    id = "mem-cli-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Codrift.Paths.initiative_dir(id)) end)
    {:ok, id: id}
  end

  # Every subcommand prints exactly one JSON document, so decoding the captured
  # output is also the assertion that nothing else was written to stdout.
  defp run_json(argv) do
    argv |> then(&capture_io(fn -> CLI.run(&1) end)) |> String.trim() |> JSON.decode!()
  end

  describe "add" do
    test "returns the new row's id, type and source", %{id: id} do
      result = run_json(["add", id, "decision", "we use JWT, not sessions"])

      assert is_integer(result["id"])
      assert result["chunk_type"] == "decision"
      assert result["source"] == "user"
    end

    test "--source overrides the default attribution", %{id: id} do
      result = run_json(["add", id, "note", "content", "--source=conductor"])
      assert result["source"] == "conductor"
    end

    test "a --source flag is found wherever it sits in the argv", %{id: id} do
      result = run_json(["add", id, "note", "content", "--other", "--source=agent-7"])
      assert result["source"] == "agent-7"
    end

    test "the entry is really stored, not just echoed back", %{id: id} do
      run_json(["add", id, "snippet", "git worktree add ../wt"])

      assert [%{content: "git worktree add ../wt"}] = Memory.list(id, "snippet")
    end
  end

  describe "search" do
    setup %{id: id} do
      Memory.add(id, "decision", "Checkout uses Stripe PaymentIntents", "test")
      Memory.add(id, "summary", "Migrated the greeting to template literals", "test")
      :ok
    end

    test "returns matching entries as a JSON list", %{id: id} do
      results = run_json(["search", id, "Stripe"])

      assert is_list(results)
      assert Enum.any?(results, &(&1["content"] =~ "Stripe"))
    end

    test "a query that matches nothing is an empty list, not an error", %{id: id} do
      assert [] == run_json(["search", id, "zzzznothingmatches"])
    end

    test "extra argv after the query is ignored rather than rejected", %{id: id} do
      assert is_list(run_json(["search", id, "Stripe", "and", "more"]))
    end
  end

  describe "recent" do
    setup %{id: id} do
      for n <- 1..5, do: Memory.add(id, "note", "entry #{n}", "test")
      :ok
    end

    test "defaults to a sensible page rather than the whole store", %{id: id} do
      assert length(run_json(["recent", id])) == 5
    end

    test "an explicit limit is honoured", %{id: id} do
      assert length(run_json(["recent", id, "2"])) == 2
    end

    test "a nonsense limit falls back to the default instead of crashing", %{id: id} do
      # A shell can pass anything here; the command must not die on "abc".
      assert length(run_json(["recent", id, "abc"])) == 5
      assert length(run_json(["recent", id, "0"])) == 5
      assert length(run_json(["recent", id, "-3"])) == 5
    end
  end

  describe "list" do
    test "returns only the entries of the named type", %{id: id} do
      Memory.add(id, "decision", "a decision", "test")
      Memory.add(id, "note", "a note", "test")

      results = run_json(["list", id, "decision"])

      assert length(results) == 1
      assert hd(results)["content"] == "a decision"
    end

    test "a type with no entries is an empty list", %{id: id} do
      assert [] == run_json(["list", id, "snippet"])
    end
  end

  describe "stats" do
    test "reports the store's shape for an initiative with entries", %{id: id} do
      Memory.add(id, "decision", "one", "test")
      Memory.add(id, "note", "two", "test")

      stats = run_json(["stats", id])
      assert is_map(stats)
    end

    test "an initiative with no memory still answers", %{id: id} do
      assert is_map(run_json(["stats", id]))
    end
  end

  describe "delete" do
    test "removes the entry and echoes the id it removed", %{id: id} do
      {:ok, rowid} = Memory.add(id, "note", "delete me", "test")

      assert %{"deleted" => ^rowid} = run_json(["delete", id, to_string(rowid)])
      assert [] == Memory.list(id, "note")
    end
  end

  describe "usage" do
    test "an unrecognised subcommand prints usage listing every command" do
      output = capture_io(fn -> CLI.run(["not-a-subcommand"]) end)

      for command <- ~w[search add delete recent list stats] do
        assert output =~ "codrift memory #{command}", "usage omitted #{command}"
      end
    end

    test "usage names every valid type, so the error is actionable" do
      output = capture_io(fn -> CLI.run([]) end)

      for type <- Memory.valid_types() do
        assert output =~ type, "usage omitted the #{type} type"
      end
    end
  end
end
