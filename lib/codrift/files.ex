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

  Symlinks are fully resolved before the containment check (see `realpath/1`),
  so a link inside an allowed directory pointing outside it cannot be used to
  read arbitrary host files.

  Returns `{:ok, content}` or `{:error, reason}` where reason is `:forbidden`
  (outside the allowed roots), `:too_large`, `:not_a_file`, or a posix error.
  """
  @spec read_within([String.t()], String.t()) :: {:ok, binary()} | {:error, atom()}
  def read_within(allowed_dirs, path) do
    case resolve_within(allowed_dirs, path) do
      {:ok, abs} -> read_regular(abs)
      :error -> {:error, :forbidden}
    end
  end

  @doc """
  Writes `content` to `path` only if it resolves inside one of `allowed_dirs`.

  Symlinks are fully resolved before the containment check, so a link inside
  an allowed directory pointing outside it cannot be used to overwrite
  arbitrary host files.

  Creates the file if absent (within an allowed root) or overwrites it. Returns
  `:ok` or `{:error, :forbidden | :not_a_file | posix}`.
  """
  @spec write_within([String.t()], String.t(), binary()) :: :ok | {:error, atom()}
  def write_within(allowed_dirs, path, content) when is_binary(content) do
    case resolve_within(allowed_dirs, path) do
      :error -> {:error, :forbidden}
      {:ok, abs} -> if File.dir?(abs), do: {:error, :not_a_file}, else: File.write(abs, content)
    end
  end

  # Resolves `path` (following every symlink) and returns `{:ok, real_path}`
  # when it lands inside one of the (equally resolved) allowed roots. Both
  # sides are resolved so roots that live behind symlinks themselves — e.g.
  # /tmp on macOS — still contain their own files.
  defp resolve_within(allowed_dirs, path) do
    with {:ok, abs} <- realpath(path),
         true <- Enum.any?(allowed_dirs, &resolved_root_contains?(&1, abs)) do
      {:ok, abs}
    else
      _ -> :error
    end
  end

  defp resolved_root_contains?(dir, abs) do
    case realpath(dir) do
      {:ok, base} -> inside?(abs, base)
      _ -> false
    end
  end

  @max_symlink_hops 40

  @doc """
  Resolves every symlink in `path`, like `realpath(3)` — but trailing
  components that do not exist yet are kept (so a target file may be created
  afterwards). Returns `{:error, :eloop}` when symlink resolution does not
  terminate within #{@max_symlink_hops} hops.
  """
  @spec realpath(String.t()) :: {:ok, String.t()} | {:error, :eloop}
  def realpath(path) do
    path |> Path.expand() |> Path.split() |> do_realpath("/", @max_symlink_hops)
  end

  defp do_realpath(_comps, _acc, hops) when hops < 0, do: {:error, :eloop}
  defp do_realpath([], acc, _hops), do: {:ok, acc}
  defp do_realpath(["/" | rest], _acc, hops), do: do_realpath(rest, "/", hops)
  defp do_realpath(["." | rest], acc, hops), do: do_realpath(rest, acc, hops)
  defp do_realpath([".." | rest], acc, hops), do: do_realpath(rest, Path.dirname(acc), hops)

  defp do_realpath([comp | rest], acc, hops) do
    candidate = Path.join(acc, comp)

    case :file.read_link(candidate) do
      {:ok, target} ->
        # Splice the link target's components in and keep resolving — the
        # target may itself contain symlinks, `..`, or point at another link.
        target = IO.chardata_to_string(target)

        case Path.type(target) do
          :absolute -> do_realpath(Path.split(target) ++ rest, "/", hops - 1)
          _ -> do_realpath(Path.split(target) ++ rest, acc, hops - 1)
        end

      {:error, _} ->
        # Not a symlink (regular file/dir, or does not exist yet).
        do_realpath(rest, candidate, hops)
    end
  end

  @doc """
  Writes `content` to `path` atomically: writes to a temp file next to the
  target, then renames over it. A crash mid-write leaves the previous file
  intact instead of a truncated one. Creates parent directories as needed.
  """
  @spec write_atomic!(String.t(), iodata()) :: :ok
  def write_atomic!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
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
