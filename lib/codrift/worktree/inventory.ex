defmodule Codrift.Worktree.Inventory do
  @moduledoc """
  Finds every Codrift-managed worktree on disk and says whether anything still
  claims it.

  Worktrees already live in one predictable place —
  `~/.codrift/initiatives/{id}/worktrees/{slug}` — but nothing could enumerate
  them, so a worktree left behind by a deleted initiative or a removed directory
  simply stayed on disk, holding a checkout and a branch, invisible to everyone.
  This module is the missing read side, and `prune/2` the write side.

  A worktree is **linked** when the initiative that owns its folder still exists
  *and* still has a directory entry pointing at it. Anything else is an
  **orphan**, with a reason:

    * `:initiative_deleted` — no initiative has that id any more
    * `:not_referenced` — the initiative exists but no directory of it points here

  Separately, git keeps its own registry inside each source repository, and that
  can outlive the folder: remove a worktree directory by hand and the repo still
  lists it as `prunable`. `stale_registrations/1` finds those.

  ## Purity

  Like `Codrift.Memory` and `Codrift.CLI.Initiative`, this takes the initiatives
  as an argument rather than calling `Codrift.Initiative.Store`, so `codrift
  prune` works through `bin/codrift eval` on a system with no supervision tree.
  """

  alias Codrift.{Paths, Worktree}

  @type entry :: %{
          path: String.t(),
          initiative_id: String.t(),
          initiative_name: String.t() | nil,
          source_path: String.t() | nil,
          branch: String.t(),
          dirty?: boolean(),
          state: :linked | :orphan,
          reason: nil | :initiative_deleted | :not_referenced
        }

  @doc """
  Every Codrift-managed worktree on disk, classified against `initiatives`.

  Sorted by path so output is stable between runs — a listing that reorders
  itself is useless for spotting what changed.
  """
  @spec scan([Codrift.Initiative.t()]) :: [entry()]
  def scan(initiatives) do
    by_id = Map.new(initiatives, &{&1.id, &1})

    Paths.initiatives_base()
    |> worktree_dirs()
    |> Enum.map(&describe(&1, by_id))
    |> Enum.sort_by(& &1.path)
  end

  defp orphans(initiatives), do: initiatives |> scan() |> Enum.filter(&(&1.state == :orphan))

  @doc """
  Worktrees git still lists in a source repository whose folder is gone.

  These cost nothing on disk but make `git worktree list` lie and can block
  re-creating a worktree at the same path. Codrift's own test suite has leaked
  these into real repositories, which is what prompted this.
  """
  @spec stale_registrations([Codrift.Initiative.t()]) :: [%{repo: String.t(), path: String.t()}]
  def stale_registrations(initiatives) do
    initiatives
    |> Enum.flat_map(& &1.dirs)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.filter(&Worktree.git_repo?/1)
    |> Enum.flat_map(&prunable_in/1)
  end

  @doc """
  Removes orphaned worktrees and clears stale git registrations.

  **Reports without touching anything unless `force: true`.** Deleting a
  worktree can destroy uncommitted work, so the default is a dry run and the
  caller has to say so twice. Committed work survives regardless: removing a
  worktree does not delete its branch.

  Dirty orphans are removed under `force: true` like any other, but every entry
  carries `dirty?`, and the dry run is the place to notice.

  Returns `%{dry_run: bool, orphans: [...], stale: [...], removed: [...], failed: [...]}`.
  """
  @spec prune([Codrift.Initiative.t()], keyword()) :: map()
  def prune(initiatives, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    found = orphans(initiatives)
    stale = stale_registrations(initiatives)

    {removed, failed} =
      if force?, do: remove_all(found), else: {[], []}

    if force?, do: stale |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.each(&git_prune/1)

    %{
      dry_run: not force?,
      orphans: found,
      stale: stale,
      removed: removed,
      failed: failed,
      dirty_count: Enum.count(found, & &1.dirty?)
    }
  end

  @doc """
  JSON-ready shape for one entry.

  Lives here rather than in each caller because the MCP tools and the CLI both
  emit it, and two hand-written copies of the same eight fields drift the moment
  one gains a ninth.
  """
  @spec to_map(entry()) :: map()
  def to_map(entry) do
    %{
      "path" => entry.path,
      "initiative_id" => entry.initiative_id,
      "initiative_name" => entry.initiative_name,
      "source_path" => entry.source_path,
      "branch" => entry.branch,
      "dirty" => entry.dirty?,
      "state" => to_string(entry.state),
      "reason" => entry.reason && to_string(entry.reason)
    }
  end

  @doc "JSON-ready shape for a `prune/2` result."
  @spec prune_to_map(map()) :: map()
  def prune_to_map(result) do
    %{
      "dry_run" => result.dry_run,
      "orphans" => Enum.map(result.orphans, &to_map/1),
      "stale_registrations" => Enum.map(result.stale, &%{"repo" => &1.repo, "path" => &1.path}),
      "removed" => Enum.map(result.removed, & &1.path),
      "failed" => Enum.map(result.failed, &%{"path" => &1.entry.path, "error" => &1.error}),
      "dirty_count" => result.dirty_count
    }
  end

  # ── Scanning ────────────────────────────────────────────────────────────────

  defp worktree_dirs(base) do
    case File.ls(base) do
      {:ok, ids} -> Enum.flat_map(ids, &worktrees_of(base, &1))
      {:error, _} -> []
    end
  end

  defp worktrees_of(base, initiative_id) do
    dir = Worktree.worktrees_dir(Path.join(base, initiative_id))

    case File.ls(dir) do
      {:ok, slugs} ->
        for slug <- slugs, path = Path.join(dir, slug), File.dir?(path), do: {initiative_id, path}

      {:error, _} ->
        []
    end
  end

  defp describe({initiative_id, path}, by_id) do
    {state, reason} = classify(Map.get(by_id, initiative_id), path)
    status = Worktree.status(path)

    %{
      path: path,
      initiative_id: initiative_id,
      initiative_name: initiative_name(Map.get(by_id, initiative_id)),
      source_path: source_repo(path),
      branch: status.branch,
      dirty?: status.dirty?,
      state: state,
      reason: reason
    }
  end

  defp initiative_name(nil), do: nil
  defp initiative_name(%{name: name}), do: name

  defp classify(nil, _path), do: {:orphan, :initiative_deleted}

  defp classify(initiative, path) do
    if Enum.any?(initiative.dirs, &(&1.worktree_path == path)),
      do: {:linked, nil},
      else: {:orphan, :not_referenced}
  end

  # A worktree's `.git` is a file, not a directory — it holds
  # `gitdir: /path/to/repo/.git/worktrees/<name>`. Reading it is how an orphan can
  # still name the repository it came from after the initiative that created it
  # has been deleted, which is the only way `git worktree remove` can be used
  # instead of a blind `rm -rf`.
  defp source_repo(path) do
    with {:ok, contents} <- File.read(Path.join(path, ".git")),
         [_, gitdir] <- Regex.run(~r/^gitdir:\s*(.+)$/m, contents) do
      git_dir = gitdir |> String.trim() |> Path.dirname() |> Path.dirname()

      if Path.basename(git_dir) == ".git", do: Path.dirname(git_dir)
    else
      _ -> nil
    end
  end

  # ── git's own registry ──────────────────────────────────────────────────────

  defp prunable_in(repo) do
    case System.cmd("git", ["-C", repo, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split(~r/\n\s*\n/, trim: true)
        |> Enum.filter(&String.contains?(&1, "\nprunable"))
        |> Enum.flat_map(&worktree_path_in(&1, repo))

      _ ->
        []
    end
  end

  defp worktree_path_in(block, repo) do
    case Regex.run(~r/^worktree\s+(.+)$/m, block) do
      [_, path] -> [%{repo: repo, path: String.trim(path)}]
      _ -> []
    end
  end

  defp git_prune(repo) do
    System.cmd("git", ["-C", repo, "worktree", "prune"], stderr_to_stdout: true)
    :ok
  end

  # ── Removal ─────────────────────────────────────────────────────────────────

  defp remove_all(entries) do
    {ok, bad} =
      entries
      |> Enum.map(&{&1, remove_one(&1)})
      |> Enum.split_with(fn {_entry, error} -> is_nil(error) end)

    {Enum.map(ok, &elem(&1, 0)), Enum.map(bad, fn {e, err} -> %{entry: e, error: err} end)}
  end

  # nil when the worktree is gone, or the reason it is still there.
  defp remove_one(entry) do
    cond do
      not managed_path?(entry.path) ->
        # scan/1 only ever walks the managed tree, so this cannot trigger from
        # normal use. Checked anyway, because this function deletes directories.
        "refusing to delete a path outside #{Paths.initiatives_base()}"

      is_binary(entry.source_path) and Worktree.git_repo?(entry.source_path) ->
        Worktree.remove(entry.source_path, entry.path)
        left_behind(entry.path)

      true ->
        # The source repository is gone or was moved, so git cannot deregister
        # the worktree — the folder is all that is left to clean up.
        File.rm_rf(entry.path)
        left_behind(entry.path)
    end
  end

  defp left_behind(path) do
    if File.exists?(path), do: "removal left the folder in place"
  end

  # Mirrors the guard in Codrift.Initiative.Store: only paths strictly inside the
  # managed tree may be deleted, so a corrupted entry can never reach a project
  # directory.
  defp managed_path?(path) do
    base = Paths.initiatives_base()
    String.starts_with?(Path.expand(path), base <> "/")
  end
end
