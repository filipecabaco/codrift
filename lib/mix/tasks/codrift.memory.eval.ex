defmodule Mix.Tasks.Codrift.Memory.Eval do
  @shortdoc "Measures memory search recall against a labelled question set"

  @moduledoc """
  Scores `Codrift.Memory.search/2` against a set of questions with known answers.

  Retrieval quality is otherwise argued about rather than measured, and the
  failure mode it has to catch is silent: a query returns `[]`, the calling
  agent concludes the store is empty, redoes work that was already done, and
  writes a duplicate entry. Nothing errors. This task makes that a number.

      mix codrift.memory.eval
      mix codrift.memory.eval --set priv/memory_eval/default.json
      mix codrift.memory.eval --verbose

  ## Metrics

    * **empty** — questions that returned nothing at all. This is the number
      that matters most; it is the silent failure above.
    * **top-1** — the first result is a relevant entry.
    * **MRR** — mean reciprocal rank of the first relevant entry. Ranking
      quality, and the metric that stays honest on a small corpus.

  ## Gating

  Exits non-zero when a threshold is missed, so CI fails on a regression rather
  than reporting one:

      mix codrift.memory.eval --max-empty 0 --min-top1 0.7 --min-mrr 0.8

  ## Measuring a real store

  The default set is synthetic on purpose: real initiative memory is private and
  does not belong in git. To measure retrieval against a store on this machine,
  write a set containing only `questions` — with `expect` holding that store's
  real rowids — and point the task at the initiative:

      mix codrift.memory.eval --set my-questions.json --initiative 91a273...

  Without `--initiative` the entries in the set are loaded into a throwaway
  database under `System.tmp_dir!/0`, which is deleted afterwards. With it,
  nothing is written: the real store is searched as it stands.
  """

  use Mix.Task

  @switches [
    set: :string,
    initiative: :string,
    verbose: :boolean,
    max_empty: :integer,
    min_top1: :float,
    min_mrr: :float
  ]

  @default_set "priv/memory_eval/default.json"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:exqlite)

    set = load_set(Keyword.get(opts, :set, @default_set))

    {initiative, cleanup} =
      case Keyword.get(opts, :initiative) do
        nil -> seed_temp_store(set)
        id -> {id, fn -> :ok end}
      end

    try do
      results = Enum.map(set["questions"], &score(initiative, &1))
      report(set, initiative, results, opts)
      gate(results, opts)
    after
      cleanup.()
    end
  end

  # ── Scoring ─────────────────────────────────────────────────────────────────

  defp score(initiative, %{"q" => question, "expect" => expected}) do
    hits = Enum.map(Codrift.Memory.search(initiative, question), & &1.id)
    top5 = Enum.take(hits, 5)

    rank =
      hits
      |> Enum.with_index(1)
      |> Enum.find_value(fn {id, i} -> if i_in(id, expected), do: i end)

    %{
      question: question,
      expected: expected,
      hits: hits,
      empty?: hits == [],
      top1?: hits != [] and i_in(hd(hits), expected),
      hit5?: Enum.any?(top5, &i_in(&1, expected)),
      rr: if(rank, do: 1 / rank, else: 0.0)
    }
  end

  # Ids come from JSON as integers and from SQLite as integers, but a hand-written
  # set is an easy place to type a string.
  defp i_in(id, expected), do: Enum.any?(expected, &(to_string(&1) == to_string(id)))

  # ── Corpus ──────────────────────────────────────────────────────────────────

  # Seeded through the real `add/4`, not by writing SQL, so the eval exercises
  # the write path — including chunking — exactly as production does.
  defp seed_temp_store(set) do
    entries =
      set["entries"] ||
        Mix.raise(
          "eval set has no `entries`; pass --initiative to score against an existing store"
        )

    root =
      Path.join(System.tmp_dir!(), "codrift-memory-eval-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:codrift, :data_dir)
    Application.put_env(:codrift, :data_dir, root)

    initiative = "eval"

    for %{"chunk_type" => type, "content" => content} = e <- entries do
      {:ok, _} = Codrift.Memory.add(initiative, type, content, Map.get(e, "source", "eval"))
    end

    cleanup = fn ->
      File.rm_rf!(root)
      if previous, do: Application.put_env(:codrift, :data_dir, previous)
    end

    {initiative, cleanup}
  end

  # Rowids are assigned by insertion order starting at 1, so an entry's `id` in
  # the set has to match its position. Checking beats debugging a recall number
  # that is wrong for a reason no metric can show.
  defp verify_ids(entries) do
    mismatched =
      entries
      |> Enum.with_index(1)
      |> Enum.reject(fn {e, i} -> is_nil(e["id"]) or e["id"] == i end)

    for {e, i} <- mismatched do
      Mix.shell().error("entry #{inspect(e["id"])} is at position #{i}; ids must match order")
    end

    mismatched == []
  end

  defp load_set(path) do
    set =
      path
      |> File.read!()
      |> JSON.decode!()

    if set["entries"] && !verify_ids(set["entries"]) do
      Mix.raise("eval set #{path}: entry ids must equal their 1-based position")
    end

    set
  end

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp report(set, initiative, results, opts) do
    n = length(results)
    empty = Enum.count(results, & &1.empty?)

    shell = Mix.shell()
    shell.info("")
    shell.info("eval set:  #{set["name"] || "(unnamed)"}")

    shell.info(
      "corpus:    #{corpus_size(set, initiative)} entries, #{n} questions" <>
        if(set["entries"], do: "", else: " (against store #{initiative})")
    )

    shell.info("")
    shell.info("  empty      #{empty}/#{n}   #{pct(empty / n)}")
    shell.info("  top-1      #{pct(mean(results, &bool(&1.top1?)))}")
    shell.info("  MRR        #{Float.round(mean(results, & &1.rr), 3)}")
    shell.info("")

    misses = Enum.reject(results, & &1.top1?)

    cond do
      opts[:verbose] -> Enum.each(results, &explain/1)
      misses == [] -> shell.info("every question put a relevant entry first.")
      true -> Enum.each(misses, &explain/1)
    end

    shell.info("")
  end

  defp explain(r) do
    verdict =
      cond do
        r.empty? -> "EMPTY"
        r.top1? -> "ok"
        r.hit5? -> "in top 5, not first"
        true -> "not in top 5"
      end

    Mix.shell().info(
      "  " <>
        String.pad_trailing(String.slice(r.question, 0, 56), 58) <>
        String.pad_trailing(verdict, 21) <>
        "want #{ids(r.expected)} got #{ids(Enum.take(r.hits, 5))}"
    )
  end

  # A plain inspect renders [7] as a charlist, which is unreadable for rowids.
  defp ids(list), do: "[" <> Enum.map_join(list, ", ", &to_string/1) <> "]"

  defp corpus_size(%{"entries" => entries}, _initiative) when is_list(entries),
    do: length(entries)

  defp corpus_size(_set, initiative), do: Codrift.Memory.stats(initiative).total

  defp mean(results, fun), do: Enum.sum(Enum.map(results, fun)) / length(results)
  defp bool(true), do: 1.0
  defp bool(false), do: 0.0
  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)}%"

  # ── Gating ──────────────────────────────────────────────────────────────────

  defp gate(results, opts) do
    failures =
      [
        check(opts[:max_empty], Enum.count(results, & &1.empty?), :at_most, "empty"),
        check(opts[:min_top1], mean(results, &bool(&1.top1?)), :at_least, "top-1"),
        check(opts[:min_mrr], mean(results, & &1.rr), :at_least, "MRR")
      ]
      |> Enum.reject(&is_nil/1)

    if failures != [] do
      Enum.each(failures, &Mix.shell().error/1)
      Mix.raise("memory search eval: #{length(failures)} threshold(s) missed")
    end
  end

  defp check(nil, _actual, _dir, _label), do: nil

  defp check(bound, actual, :at_most, label) when actual > bound,
    do: "#{label}: #{fmt(actual)} exceeds the allowed #{fmt(bound)}"

  defp check(bound, actual, :at_least, label) when actual < bound,
    do: "#{label}: #{fmt(actual)} is below the required #{fmt(bound)}"

  defp check(_bound, _actual, _dir, _label), do: nil

  defp fmt(v) when is_integer(v), do: Integer.to_string(v)
  defp fmt(v), do: :erlang.float_to_binary(v * 1.0, decimals: 3)
end
