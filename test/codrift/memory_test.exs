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
end
