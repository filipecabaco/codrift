defmodule Codrift.TUI.DirPicker do
  @moduledoc """
  Filesystem directory autocomplete with fuzzy matching for the directory
  input modal.

  ## Matching and ranking

  Results are scored in three tiers (lower = better match):

  | Score | Condition |
  |-------|-----------|
  | `0` | Entry name starts with the query |
  | `1` | Entry name contains the query as a substring |
  | `2` | Query characters appear in order (fuzzy subsequence) |

  Within each tier entries are sorted alphabetically.

  ## Example

  Typing `"prj"` in `$HOME` might return:

      /home/user/projects        # score 0 — starts with "prj"? no → score 2 (subsequence p-r-j)
      /home/user/project-alpha   # score 2
      /home/user/proj-backup     # score 1 — "prj" is a substring of "proj-backup"? no → score 2

  Typing `"proj"`:

      /home/user/project-alpha   # score 0 — starts with "proj"
      /home/user/projects        # score 0
      /home/user/old-projects    # score 1 — contains "proj"
  """

  @max_suggestions 10

  @doc """
  Returns up to #{@max_suggestions} subdirectories that fuzzy-match `input`,
  ordered by match quality then alphabetically.

  An empty string or `"~"` starts from `$HOME`. A trailing `/` lists the
  directory itself. Otherwise the basename is fuzzy-matched against entries
  in the inferred parent directory.
  """
  def suggestions(""), do: suggestions(Path.expand("~"))

  def suggestions(input) do
    expanded = Path.expand(input)

    {parent, partial} =
      if String.ends_with?(input, "/"),
        do: {expanded, ""},
        else: {Path.dirname(expanded), Path.basename(expanded)}

    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn e -> File.dir?(Path.join(parent, e)) end)
        |> score_and_sort(partial)
        |> Enum.take(@max_suggestions)
        |> Enum.map(fn e -> Path.join(parent, e) end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Computes a fuzzy match score for `entry` against `query`.

  Returns `0` (prefix), `1` (substring), `2` (subsequence), or
  `:no_match` when the query cannot be matched at all.
  """
  def score(entry, ""), do: {0, entry}

  def score(entry, query) do
    lower = String.downcase(entry)
    q = String.downcase(query)

    cond do
      String.starts_with?(lower, q) -> {0, entry}
      String.contains?(lower, q) -> {1, entry}
      subsequence?(String.graphemes(lower), String.graphemes(q)) -> {2, entry}
      true -> :no_match
    end
  end

  @doc """
  Moves the suggestion cursor by `delta` (+1 or -1) and syncs the
  TextInput to the highlighted path.

  Returns the updated state map.
  """
  def move_cursor(state, delta) do
    max_idx = max(length(state.modal.dir_picker.suggestions) - 1, 0)
    new_cursor = min(max(state.modal.dir_picker.cursor + delta, 0), max_idx)

    case Enum.at(state.modal.dir_picker.suggestions, new_cursor) do
      nil ->
        %{
          state
          | modal: %{state.modal | dir_picker: %{state.modal.dir_picker | cursor: new_cursor}}
        }

      path ->
        ExRatatui.text_input_set_value(state.modal.input, path)

        %{
          state
          | modal: %{state.modal | dir_picker: %{state.modal.dir_picker | cursor: new_cursor}}
        }
    end
  end

  @doc """
  Tab-completes the TextInput to the selected suggestion followed by `/`,
  then refreshes the suggestion list.

  Returns the updated state map.
  """
  def complete(state) do
    path =
      case Enum.at(state.modal.dir_picker.suggestions, state.modal.dir_picker.cursor) do
        nil -> ExRatatui.text_input_get_value(state.modal.input)
        p -> p
      end

    completed = if String.ends_with?(path, "/"), do: path, else: path <> "/"
    ExRatatui.text_input_set_value(state.modal.input, completed)

    %{
      state
      | modal: %{state.modal | dir_picker: %{suggestions: suggestions(completed), cursor: 0}}
    }
  end

  @doc """
  Re-computes suggestions from the current TextInput value and resets the
  cursor. Call after every keystroke in the `:new_dir` modal.

  Returns the updated state map.
  """
  def sync(state) do
    typed = ExRatatui.text_input_get_value(state.modal.input)
    %{state | modal: %{state.modal | dir_picker: %{suggestions: suggestions(typed), cursor: 0}}}
  end

  defp score_and_sort(entries, "") do
    Enum.sort(entries)
  end

  defp score_and_sort(entries, partial) do
    entries
    |> Enum.map(fn e -> score(e, partial) end)
    |> Enum.reject(fn result -> result == :no_match end)
    |> Enum.sort()
    |> Enum.map(fn {_score, e} -> e end)
  end

  defp subsequence?([], [_ | _]), do: false
  defp subsequence?(_, []), do: true
  defp subsequence?([h | t], [h | q_rest]), do: subsequence?(t, q_rest)
  defp subsequence?([_ | t], query), do: subsequence?(t, query)
end
