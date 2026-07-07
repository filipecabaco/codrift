defmodule Codrift.Files do
  @moduledoc """
  Filesystem listing and reading helpers scoped to a directory.

  Listing respects `.gitignore` via `git ls-files` (with a naive fallback for
  non-git directories). Reading is guarded so the web UI can only preview files
  that resolve *inside* an allowed directory — never arbitrary host paths.
  """

  # Directories skipped during the non-git fallback traversal.
  @ignored_dirs ~w[_build deps node_modules .git .elixir_ls priv/plts
                   __pycache__ .venv venv dist build target .next .nuxt
                   .cache vendor coverage .tox]

  @max_preview_bytes 512_000

  @doc """
  Returns relative file paths under `base`, sorted, respecting `.gitignore`
  when `base` is a git repository.
  """
  @spec list_relative(String.t()) :: [String.t()]
  def list_relative(base) do
    case git_ls(base) do
      [_ | _] = files -> Enum.sort(files)
      [] -> base |> naive_walk(base) |> Enum.sort()
    end
  end

  @doc """
  Lists immediate subdirectories for path autocompletion in the "add directory"
  picker.

  Expands a leading `~` to the user's home, then decides which directory to
  enumerate: the input itself when it already points at a directory (or ends
  with a separator), otherwise its parent — so a partially-typed trailing
  fragment (e.g. `~/Doc`) lists the parent and lets the caller fuzzy-match.

  Returns `%{base: absolute_dir, entries: [child_dir_name]}` with entries sorted.
  Hidden dotfolders are included so users can navigate into them. Unreadable or
  nonexistent directories yield an empty `entries` list rather than an error.
  """
  @spec list_subdirs(String.t()) :: %{base: String.t(), entries: [String.t()]}
  def list_subdirs(input) when is_binary(input) do
    expanded = expand_home(input)

    base =
      cond do
        String.ends_with?(expanded, "/") -> expanded
        File.dir?(expanded) -> expanded
        true -> Path.dirname(expanded)
      end

    entries =
      case File.ls(base) do
        {:ok, names} ->
          names
          |> Enum.filter(&File.dir?(Path.join(base, &1)))
          |> Enum.sort()

        {:error, _} ->
          []
      end

    %{base: Path.expand(base), entries: entries}
  end

  # Elixir's Path.expand does not perform tilde expansion, so handle a leading
  # `~` explicitly; everything else is returned untouched (the caller may still
  # be mid-typing a relative fragment).
  defp expand_home("~"), do: System.user_home!()
  defp expand_home("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_home(other), do: other

  @doc """
  Reads `path` only if it resolves inside one of `allowed_dirs`.

  Returns `{:ok, content}` or `{:error, reason}` where reason is `:forbidden`
  (outside the allowed roots), `:too_large`, `:not_a_file`, or a posix error.
  """
  @spec read_within([String.t()], String.t()) :: {:ok, binary()} | {:error, atom()}
  def read_within(allowed_dirs, path) do
    abs = Path.expand(path)

    if Enum.any?(allowed_dirs, &inside?(abs, &1)) do
      read_regular(abs)
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Writes `content` to `path` only if it resolves inside one of `allowed_dirs`.

  Creates the file if absent (within an allowed root) or overwrites it. Returns
  `:ok` or `{:error, :forbidden | :not_a_file | posix}`.
  """
  @spec write_within([String.t()], String.t(), binary()) :: :ok | {:error, atom()}
  def write_within(allowed_dirs, path, content) when is_binary(content) do
    abs = Path.expand(path)

    cond do
      not Enum.any?(allowed_dirs, &inside?(abs, &1)) -> {:error, :forbidden}
      File.dir?(abs) -> {:error, :not_a_file}
      true -> File.write(abs, content)
    end
  end

  defp read_regular(abs) do
    case File.stat(abs) do
      {:ok, %{type: :regular, size: size}} when size <= @max_preview_bytes -> File.read(abs)
      {:ok, %{type: :regular}} -> {:error, :too_large}
      {:ok, _} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inside?(abs, base) do
    expanded = Path.expand(base)
    abs == expanded or String.starts_with?(abs, expanded <> "/")
  end

  defp git_ls(base) do
    case System.cmd("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
           cd: base,
           stderr_to_stdout: false
         ) do
      {output, 0} -> String.split(output, "\n", trim: true)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp naive_walk(base, path) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @ignored_dirs))
        |> Enum.flat_map(&walk_child(base, Path.join(path, &1)))

      {:error, _} ->
        []
    end
  end

  defp walk_child(base, child) do
    if File.dir?(child),
      do: naive_walk(base, child),
      else: [Path.relative_to(child, base)]
  end
end
