defmodule Codrift.Worktree do
  @moduledoc """
  Pure functions for managing git worktrees per initiative directory.

  Worktrees are stored inside the initiative's context folder:

      {context_path}/worktrees/{dir-slug}/

  where `context_path` is `~/.codrift/initiatives/{initiative_id}/` by default
  (configurable so tests can use a temp directory).

  Each worktree gets its own branch:

      codrift/{initiative_id_prefix}/{dir-slug}
  """

  require Logger

  @doc "Returns true when `path` is a git repository (has a .git entry)."
  def git_repo?(path) do
    File.exists?(Path.join(path, ".git"))
  end

  @doc "Returns the worktree directory path given the initiative context folder and source path."
  def worktree_path(context_path, source_path) do
    Path.join(context_path, "worktrees/#{slug(source_path)}")
  end

  @doc "Returns the git branch name for a given initiative and source path."
  def branch_name(initiative_id, source_path) do
    "codrift/#{String.slice(initiative_id, 0, 8)}/#{slug(source_path)}"
  end

  @doc """
  Idempotently creates a git worktree for `source_path` under `context_path`.

  Returns `{:ok, worktree_path}` on success, or `{:error, reason}` on failure.
  """
  def ensure(context_path, initiative_id, source_path) do
    if not git_repo?(source_path) do
      {:error, "#{source_path} is not a git repository"}
    else
      wt_path = worktree_path(context_path, source_path)

      if File.dir?(wt_path) do
        {:ok, wt_path}
      else
        File.mkdir_p!(Path.dirname(wt_path))
        branch = branch_name(initiative_id, source_path)

        case create_worktree(source_path, wt_path, branch) do
          :ok -> {:ok, wt_path}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Returns the current status of a worktree.

  Returns `%{branch: String.t(), dirty?: boolean()}` on success, or
  `%{branch: "unknown", dirty?: false}` when the path is not a valid git repo.
  """
  def status(worktree_path) do
    branch =
      case System.cmd("git", ["branch", "--show-current"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {output, 0} -> String.trim(output)
        _ -> "unknown"
      end

    dirty? =
      case System.cmd("git", ["status", "--short"],
             cd: worktree_path,
             stderr_to_stdout: true
           ) do
        {output, 0} -> output |> String.trim() |> String.length() > 0
        _ -> false
      end

    %{branch: branch, dirty?: dirty?}
  end

  @doc """
  Removes a git worktree.

  Runs `git worktree remove --force` from the source repo. Falls back to
  `File.rm_rf/1` when the git command fails (e.g. the source repo was moved).
  """
  def remove(source_path, worktree_path) do
    case System.cmd(
           "git",
           ["-C", source_path, "worktree", "remove", "--force", worktree_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning("git worktree remove exited #{code}: #{String.trim(output)}")
        File.rm_rf(worktree_path)
        :ok
    end
  end

  # Tries to create the worktree with a new branch. If the branch already
  # exists (re-adding a previously removed dir), retries without -b.
  defp create_worktree(source_path, wt_path, branch) do
    case System.cmd(
           "git",
           ["-C", source_path, "worktree", "add", "-b", branch, wt_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_first_output, _} ->
        case System.cmd(
               "git",
               ["-C", source_path, "worktree", "add", wt_path, branch],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            :ok

          {output, code} ->
            {:error, "git worktree add failed (#{code}): #{String.trim(output)}"}
        end
    end
  end

  # Converts an absolute path into a filesystem-safe slug used as the
  # worktree directory name and branch suffix.
  defp slug(path) do
    path
    |> Path.expand()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end
end
