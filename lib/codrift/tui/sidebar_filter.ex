defmodule Codrift.TUI.SidebarFilter do
  @moduledoc """
  Filter state and matching logic for the TUI sidebar.

  Holds a `%{query: String.t(), active: boolean()}` struct. The `active` flag
  distinguishes "user is currently typing" from "filter widget is shown but
  input is idle". `visible?/1` returns true for either state.

  ## Filter modes

  The mode is inferred automatically from the query:

  | Prefix / pattern | Mode | Example |
  |-----------------|------|---------|
  | Plain text | `:fuzzy` | `router` |
  | Starts with `#` | `:tag` | `#test`, `#config` |
  | Starts with `/` | `:regex` | `/\\.test\\.ts$/` |
  | Contains `*` or `?` | `:glob` | `*.test.ts`, `lib/**` |

  ### Tag groups

  `#test` → test files (`_test.`, `.spec.`, `test/`)
  `#config` → config files (`.env`, `config.`, `mix.exs`)
  `#doc` → documentation (`.md`, `README`, `docs/`)
  `#schema` → schema/migration files
  `#router` → router/routes files
  Unknown `#tag` → substring match on the tag word.

  ## Extensibility

  Add new tag groups to `@tag_patterns`, new mode prefixes to `mode/1`,
  or new match clauses to `do_match/3`.
  """

  @type mode :: :fuzzy | :glob | :regex | :tag
  @type t :: %{query: String.t(), active: boolean()}

  @tag_patterns %{
    "test" => ~w[_test. .test. .spec. _spec. test/ tests/],
    "config" => ~w[config. .env mix.exs application. settings.],
    "doc" => ~w[.md .mdx readme changelog license docs/ documentation/],
    "schema" => ~w[schema. _schema. schemas/],
    "migration" => ~w[migrations/ _migration. priv/repo/],
    "router" => ~w[router. routes. _router.]
  }

  def new, do: %{query: "", active: false}

  def activate(f), do: %{f | active: true}
  def deactivate(_f), do: %{query: "", active: false}

  def put_char(f, char), do: %{f | query: f.query <> char}

  def backspace(%{query: ""} = f), do: f
  def backspace(f), do: %{f | query: String.slice(f.query, 0..-2//1)}

  def active?(%{active: a}), do: a

  def visible?(%{active: true}), do: true
  def visible?(%{query: q}), do: q != ""

  def filtering?(%{query: q}), do: q != ""

  @doc "Returns the current filter mode inferred from the query."
  @spec mode(t()) :: mode()
  def mode(%{query: ""}), do: :fuzzy
  def mode(%{query: "/" <> _}), do: :regex
  def mode(%{query: "#" <> _}), do: :tag

  def mode(%{query: q}) do
    if String.contains?(q, ["*", "?"]), do: :glob, else: :fuzzy
  end

  @doc "Returns true when `str` matches the filter under the active mode."
  def matches?(%{query: ""}, _str), do: true

  def matches?(filter, str) do
    do_match(mode(filter), filter.query, str)
  end

  @doc """
  Filter tree entries.

  When the query is non-empty, filters `all_files` (the complete flat file list,
  independent of expand state) down to matching `{:tree_file, …}` entries.
  When the query is empty, returns `entries` (the normal expand-aware view).
  """
  def apply_tree(%{query: ""}, _all_files, entries), do: entries

  def apply_tree(filter, all_files, _entries) do
    Enum.filter(all_files, fn {:tree_file, path, _depth} ->
      matches?(filter, Path.basename(path)) or matches?(filter, path)
    end)
  end

  @doc """
  Filter diff sidebar entries.

  When the query is non-empty, retains only `{:diff_file, …}` entries whose
  path matches. When empty, returns the full entry list unchanged.
  """
  def apply_diff(%{query: ""}, entries), do: entries

  def apply_diff(filter, entries) do
    Enum.filter(entries, fn
      {:diff_file, _dir, path, _adds, _dels} ->
        matches?(filter, Path.basename(path)) or matches?(filter, path)

      _ ->
        false
    end)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp do_match(:fuzzy, query, str) do
    String.contains?(String.downcase(str), String.downcase(query))
  end

  defp do_match(:glob, pattern, str) do
    regex_str = glob_to_regex(String.downcase(pattern))

    case Regex.compile(regex_str) do
      {:ok, regex} -> Regex.match?(regex, String.downcase(str))
      _ -> false
    end
  end

  defp do_match(:regex, "/" <> rest, str) do
    pattern = String.trim_trailing(rest, "/")

    case Regex.compile(pattern, "i") do
      {:ok, regex} -> Regex.match?(regex, str)
      _ -> false
    end
  end

  defp do_match(:tag, "#" <> tag, str) do
    lower_str = String.downcase(str)
    lower_tag = String.downcase(tag)

    case Map.get(@tag_patterns, lower_tag) do
      nil -> String.contains?(lower_str, lower_tag)
      patterns -> Enum.any?(patterns, &String.contains?(lower_str, &1))
    end
  end

  defp glob_to_regex(pattern) do
    pattern
    |> String.graphemes()
    |> Enum.map_join(fn
      "*" -> ".*"
      "?" -> "."
      c -> Regex.escape(c)
    end)
  end
end
