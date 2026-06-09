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

  @doc "Toggles expanded/collapsed state for `path` in the expanded `MapSet`."
  @spec toggle_expand(MapSet.t(), String.t()) :: MapSet.t()
  def toggle_expand(expanded, path) do
    if MapSet.member?(expanded, path),
      do: MapSet.delete(expanded, path),
      else: MapSet.put(expanded, path)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

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
