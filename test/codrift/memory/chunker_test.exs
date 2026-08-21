defmodule Codrift.Memory.ChunkerTest do
  use ExUnit.Case, async: true

  alias Codrift.Memory.Chunker

  doctest Codrift.Memory.Chunker

  describe "split/1" do
    test "leaves an entry shorter than one chunk alone" do
      assert Chunker.split("Use JWT, not sessions.") == ["Use JWT, not sessions."]
    end

    test "splits a long entry into several chunks" do
      chunks = Chunker.split(String.duplicate("alpha beta gamma delta ", 100))

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(String.length(&1) <= Chunker.size() + 32))
    end

    # A fact that straddles a boundary has to survive whole in one of the two
    # chunks sharing it, or chunking would lose exactly what search is for.
    test "consecutive chunks overlap" do
      words = for i <- 1..300, do: "word#{i}"
      [first, second | _] = Chunker.split(Enum.join(words, " "))

      tail = first |> String.split(" ") |> Enum.take(-5)
      assert Enum.all?(tail, &String.contains?(second, &1))
    end

    test "every word of the entry survives somewhere" do
      words = for i <- 1..400, do: "word#{i}"
      joined = Chunker.split(Enum.join(words, " ")) |> Enum.join(" ") |> String.split(" ")

      assert Enum.all?(words, &(&1 in joined))
    end

    # Guards the take/4 base case: a single token longer than the chunk size must
    # still be emitted, not produce an empty chunk and loop forever.
    test "a single token longer than a chunk is emitted whole" do
      giant = String.duplicate("x", Chunker.size() * 3)

      assert Chunker.split(giant) == [giant]
    end

    test "always yields at least one chunk, so no entry is unreachable" do
      assert Chunker.split("") == [""]
      assert Chunker.split("   ") == ["   "]
      assert [_ | _] = Chunker.split("a")
    end
  end
end
