defmodule Codrift.TUI.Tree do
  @moduledoc """
  Pure functions for building and navigating the file tree in tree view mode.

  ## Entry types

      {:tree_dir, path :: String.t(), depth :: non_neg_integer(), expanded? :: boolean()}
      {:tree_file, path :: String.t(), depth :: non_neg_integer()}
  """

  alias Codrift.Initiative.DirEntry

  @type entry ::
          {:tree_dir, path :: String.t(), depth :: non_neg_integer(), expanded? :: boolean()}
          | {:tree_file, path :: String.t(), depth :: non_neg_integer()}

  @doc """
  Builds a flat list of visible tree entries for all dirs in the initiative.
  Dirs present in `expanded` are traversed recursively; others show only the header row.
  """
  @spec build_visible(map(), MapSet.t()) :: [entry()]
  def build_visible(initiative, expanded) do
    Enum.flat_map(initiative.dirs, fn dir_entry ->
      path = DirEntry.effective_path(dir_entry)
      build_for_dir(path, 0, expanded)
    end)
  end

  @doc """
  Returns a flat list of all `{:tree_file, path, depth}` entries for the
  initiative, used by `SidebarFilter` to search across the full file tree.

  Uses `git ls-files --cached --others --exclude-standard` as the primary
  backend so `.gitignore` patterns are respected automatically and build
  artifacts (`_build/`, `deps/`, `node_modules/`, etc.) are excluded for
  free. Falls back to a naive recursive traversal with a built-in exclusion
  list for directories that are not inside a git repository.
  """
  @spec all_files(map()) :: [entry()]
  def all_files(initiative) do
    Enum.flat_map(initiative.dirs, fn dir_entry ->
      path = DirEntry.effective_path(dir_entry)
      files_for_dir(path)
    end)
  end

  @doc "Toggles expanded/collapsed state for `path` in the expanded `MapSet`."
  @spec toggle_expand(MapSet.t(), String.t()) :: MapSet.t()
  def toggle_expand(expanded, path) do
    if MapSet.member?(expanded, path),
      do: MapSet.delete(expanded, path),
      else: MapSet.put(expanded, path)
  end

  # Directories always excluded during naive fallback traversal.
  @ignored_dirs ~w[_build deps node_modules .git .elixir_ls priv/plts
                   __pycache__ .venv venv dist build target .next .nuxt
                   .cache vendor coverage .tox]

  # ── Private ───────────────────────────────────────────────────────────────────

  defp files_for_dir(base) do
    case git_ls_files(base) do
      [_ | _] = files -> files
      [] -> list_all_files_naive(base, base, 0)
    end
  end

  defp git_ls_files(base) do
    case System.cmd(
           "git",
           ["ls-files", "--cached", "--others", "--exclude-standard"],
           cd: base,
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn rel ->
          depth = max(length(Path.split(rel)) - 1, 0)
          {:tree_file, Path.join(base, rel), depth}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp list_all_files_naive(base, path, depth) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @ignored_dirs))
        |> Enum.sort()
        |> Enum.flat_map(&file_or_recurse_naive(base, Path.join(path, &1), depth))

      {:error, _} ->
        []
    end
  end

  defp file_or_recurse_naive(base, child, depth) do
    if File.dir?(child),
      do: list_all_files_naive(base, child, depth + 1),
      else: [{:tree_file, child, depth}]
  end

  defp build_for_dir(path, depth, expanded) do
    is_expanded = MapSet.member?(expanded, path)
    header = {:tree_dir, path, depth, is_expanded}

    if is_expanded and File.dir?(path) do
      [header | list_children(path, depth + 1, expanded)]
    else
      [header]
    end
  end

  defp list_children(path, depth, expanded) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(&child_entries(Path.join(path, &1), depth, expanded))

      {:error, _} ->
        []
    end
  end

  defp child_entries(child, depth, expanded) do
    if File.dir?(child),
      do: build_for_dir(child, depth, expanded),
      else: [{:tree_file, child, depth}]
  end
end
