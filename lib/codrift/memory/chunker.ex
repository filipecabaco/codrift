defmodule Codrift.Memory.Chunker do
  @moduledoc """
  Splits a memory entry into overlapping chunks for indexing.

  BM25 normalises a term's weight by document length, so a 2 kB entry that
  mentions "keepalive" once ranks below a 200-byte one that does — and real
  entries run 0.6–2.7 kB, because an agent writing a decision writes the whole
  rationale. Indexing chunks instead of whole entries removes that penalty:
  the entry is judged by its most relevant passage rather than by its average.

  Measured on 34 hand-labelled questions over 22 real entries, chunking at these
  settings moved top-1 accuracy from 76% to 82% and MRR from 0.87 to 0.90 — the
  only change in the lexical stack that improved ranking rather than just
  recall. See `mix codrift.memory.eval`.

  Chunks overlap so a sentence spanning a boundary still appears whole in one of
  the two chunks that share it. Splitting is on whitespace rather than sentence
  punctuation: entries are as often config keys and paths as prose, and a
  sentence splitter mangles `docs/hosting.md A1.` more often than it helps.

  Always returns at least one chunk, so every entry is reachable through the
  chunk index and searching it never needs a whole-document fallback.
  """

  @size 600
  @overlap 150

  @doc "Chunk size in characters."
  @spec size() :: pos_integer()
  def size, do: @size

  @doc """
  Splits `content` into overlapping chunks, longest-first order preserved.

      iex> Codrift.Memory.Chunker.split("short entry")
      ["short entry"]

      iex> content = String.duplicate("word ", 400)
      iex> chunks = Codrift.Memory.Chunker.split(content)
      iex> length(chunks) > 1
      true
  """
  @spec split(String.t()) :: [String.t()]
  def split(content) when is_binary(content) do
    case String.split(content, ~r/\s+/, trim: true) do
      [] -> [content]
      words -> build(words, [])
    end
  end

  def split(_), do: [""]

  defp build([], acc), do: Enum.reverse(acc)

  defp build(words, acc) do
    {chunk, rest} = take(words, @size, [], 0)
    text = Enum.join(chunk, " ")

    if rest == [] do
      Enum.reverse([text | acc])
    else
      # Step back over the tail of the chunk just emitted, so the next one opens
      # with the words this one closed on.
      {tail, _} = take(Enum.reverse(chunk), @overlap, [], 0)
      build(Enum.reverse(tail) ++ rest, [text | acc])
    end
  end

  defp take([], _limit, taken, _len), do: {Enum.reverse(taken), []}

  defp take([word | rest] = all, limit, taken, len) do
    # The first word is always taken, however long: a single 2 kB token would
    # otherwise produce an empty chunk and loop forever.
    if len > 0 and len + String.length(word) > limit do
      {Enum.reverse(taken), all}
    else
      take(rest, limit, [word | taken], len + String.length(word) + 1)
    end
  end
end
