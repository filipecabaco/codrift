defmodule Codrift.Branch do
  @moduledoc """
  A git branch per initiative, checked out in the project directory itself.

  The lighter half of `Codrift.Worktree`: a worktree gives every directory its
  own checkout (isolated, but a full copy on disk per initiative), while a
  branch keeps one working copy and just moves it onto initiative-specific
  history. Use a branch when the isolation of a worktree is not worth its cost.

  Branch names are derived from the initiative, so every directory in it lands
  on the same branch name:

      codrift/{item-id-or-name-slug}

  Switching is refused when the working tree has uncommitted changes — carrying
  a dirty tree onto another branch is how work gets lost.
  """

  require Logger

  alias Codrift.Worktree

  @doc """
  Branch name for an initiative: its tracker item id when it came from one,
  otherwise its name.
  """
  @spec name(Codrift.Initiative.t()) :: String.t()
  def name(%{integration: %{item_id: item_id}}) when is_binary(item_id),
    do: "codrift/" <> slug(item_id)

  def name(%{name: initiative_name}), do: "codrift/" <> slug(initiative_name)

  @doc """
  Checks out `branch` in `dir`, creating it from the current HEAD when absent.

  Returns `{:ok, branch}`, or `{:error, reason}` when `dir` is not a repository
  or has uncommitted changes.
  """
  @spec ensure(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure(dir, branch) do
    cond do
      not Worktree.git_repo?(dir) ->
        {:error, "#{dir} is not a git repository"}

      Worktree.status(dir).branch == branch ->
        {:ok, branch}

      dirty?(dir) ->
        {:error, "#{Path.basename(dir)} has uncommitted changes — commit or stash them first"}

      true ->
        checkout(dir, branch)
    end
  end

  @doc "Returns the branch currently checked out in `dir`, or `nil`."
  @spec current(String.t()) :: String.t() | nil
  def current(dir) do
    case Worktree.status(dir) do
      %{branch: "unknown"} -> nil
      %{branch: ""} -> nil
      %{branch: branch} -> branch
    end
  end

  # Codrift writes `.claude/settings.json` into every directory it manages, so
  # an untracked `.claude/` is our own noise rather than the user's work — it
  # must not block the switch.
  defp dirty?(dir) do
    case git(dir, ["status", "--porcelain"]) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&codrift_artifact?/1)
        |> Enum.any?()

      _ ->
        false
    end
  end

  defp codrift_artifact?("?? " <> path), do: String.starts_with?(path, ".claude/")
  defp codrift_artifact?(_), do: false

  defp checkout(dir, branch) do
    case git(dir, ["checkout", branch]) do
      {_, 0} ->
        {:ok, branch}

      _ ->
        case git(dir, ["checkout", "-b", branch]) do
          {_, 0} ->
            {:ok, branch}

          {output, code} ->
            {:error, "git checkout failed (#{code}): #{String.trim(output)}"}
        end
    end
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
  end
end
