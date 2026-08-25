defmodule Codrift.Git do
  @moduledoc """
  The handful of git operations the UI drives directly: fetch, rebase, commit,
  push.

  These exist because agent work lands in a worktree, and a worktree is a dead
  end until someone gets the commits out of it. Every function takes the
  directory to act in — callers are expected to have already resolved a source
  path to its worktree via `Codrift.Initiative.DirEntry.resolve/2`, so the
  operation lands where the agent actually wrote.

  Everything returns `{:ok, map}` or `{:error, message}` with git's own output
  in the message: git explains its own failures far better than a re-worded
  summary would, and "rebase failed" without the conflict list is useless.
  """

  require Logger

  alias Codrift.Worktree

  # A push to a branch the remote has never seen makes the forge print a link
  # for opening a pull/merge request. It is the one moment the URL is offered,
  # and it arrives on stderr in among the transfer progress — so catch it there
  # rather than making the user go find the branch in a browser.
  @pr_url_patterns [
    ~r{https://\S*github\.com/\S+/pull/new/\S+},
    ~r{https://\S*gitlab\.\S+/merge_requests/new\S*},
    ~r{https://\S*bitbucket\.org/\S+/pull-requests/new\S*}
  ]

  @doc """
  Fetches all remotes, pruning refs that are gone.

  Returns the number of remote-tracking refs that moved, so the caller can say
  "already up to date" rather than reporting a no-op as if it were work.
  """
  @spec fetch(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch(dir) do
    with :ok <- ensure_repo(dir) do
      case run(dir, ["fetch", "--all", "--prune"]) do
        {output, 0} -> {:ok, %{"output" => output, "changed" => output != ""}}
        {output, _} -> {:error, failure("fetch failed", output)}
      end
    end
  end

  @doc """
  Rebases the current branch onto its upstream.

  `--autostash` on purpose: an agent's checkout is nearly always dirty, and
  refusing to rebase until it is clean would make this useless exactly when it
  is wanted. A conflict aborts and restores the stash, so a failed rebase
  leaves the tree as it was found.
  """
  @spec rebase(String.t()) :: {:ok, map()} | {:error, String.t()}
  def rebase(dir) do
    with :ok <- ensure_repo(dir),
         {:ok, onto} <- rebase_target(dir) do
      case run(dir, ["rebase", "--autostash", onto]) do
        {output, 0} ->
          {:ok, %{"output" => output, "onto" => onto, "branch" => current_branch(dir)}}

        {output, _} ->
          # Leave nothing half-applied: an interactive shell would let the user
          # resolve it, but there is no shell here, so put the tree back and say
          # what collided.
          run(dir, ["rebase", "--abort"])
          {:error, failure("rebase onto #{onto} failed (aborted, nothing changed)", output)}
      end
    end
  end

  @doc """
  Stages every change in the working tree and commits it with `message`.

  Staging everything matches what the button says — the UI offers no way to
  pick hunks, so committing a subset would silently leave work behind.
  """
  @spec commit(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def commit(dir, message) do
    with {:ok, message} <- ensure_message(message),
         :ok <- ensure_repo(dir),
         :ok <- ensure_dirty(dir),
         {_, 0} <- run(dir, ["add", "-A"]),
         {output, 0} <- run(dir, ["commit", "-m", message]) do
      {:ok, %{"output" => output, "branch" => current_branch(dir), "sha" => current_sha(dir)}}
    else
      # The guards above already say what went wrong; only a git invocation
      # reaches the second clause, and there git's own output is the message.
      {:error, _} = error -> error
      {output, _} -> {:error, failure("commit failed", output)}
    end
  end

  @doc """
  Pushes the current branch, setting upstream on first push.

  The returned `pr_url` is the point of the whole thing: on a first push the
  forge prints a "create a pull request" link, and when it does not (the branch
  already has one, or already existed) a compare URL is derived from the remote
  so there is always somewhere to click.
  """
  @spec push(String.t()) :: {:ok, map()} | {:error, String.t()}
  def push(dir) do
    with :ok <- ensure_repo(dir),
         {:ok, branch} <- push_branch(dir) do
      case run(dir, ["push", "--set-upstream", "origin", branch]) do
        {output, 0} ->
          {:ok,
           %{
             "output" => output,
             "branch" => branch,
             "pr_url" => pr_url(output) || compare_url(dir, branch)
           }}

        {output, _} ->
          {:error, failure("push failed", output)}
      end
    end
  end

  @doc """
  A one-line summary of where `dir` stands: branch, dirty flag, and how far it
  has drifted from its upstream. Backs the contextual hints, so the UI can say
  "Push 2" instead of offering a push that has nothing to send.
  """
  @spec info(String.t()) :: map() | nil
  def info(dir) do
    if Worktree.git_repo?(dir) do
      {ahead, behind} = tracking_counts(dir)

      %{
        "branch" => current_branch(dir),
        "dirty" => dirty?(dir),
        "ahead" => ahead,
        "behind" => behind,
        "upstream" => upstream(dir)
      }
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp ensure_message(message) do
    case String.trim(message || "") do
      "" -> {:error, "a commit message is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp ensure_repo(dir) do
    if Worktree.git_repo?(dir), do: :ok, else: {:error, "#{dir} is not a git repository"}
  end

  defp ensure_dirty(dir) do
    if dirty?(dir), do: :ok, else: {:error, "nothing to commit — the working tree is clean"}
  end

  defp dirty?(dir) do
    case run(dir, ["status", "--porcelain"]) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  # Rebase onto the upstream when the branch tracks one. Otherwise fall back to
  # the remote's default branch: a worktree branch created by Codrift has no
  # upstream until its first push, and "rebase" on it can only sensibly mean
  # "onto the branch I came from".
  defp rebase_target(dir) do
    case upstream(dir) do
      nil ->
        case default_remote_branch(dir) do
          nil -> {:error, "no upstream and no origin/HEAD to rebase onto — fetch first"}
          branch -> {:ok, branch}
        end

      up ->
        {:ok, up}
    end
  end

  defp upstream(dir) do
    case run(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp default_remote_branch(dir) do
    case run(dir, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp push_branch(dir) do
    case current_branch(dir) do
      nil -> {:error, "detached HEAD — check out a branch before pushing"}
      branch -> {:ok, branch}
    end
  end

  defp current_branch(dir) do
    case run(dir, ["branch", "--show-current"]) do
      {output, 0} -> if String.trim(output) == "", do: nil, else: String.trim(output)
      _ -> nil
    end
  end

  defp current_sha(dir) do
    case run(dir, ["rev-parse", "--short", "HEAD"]) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp tracking_counts(dir) do
    case run(dir, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) do
      {output, 0} ->
        case output |> String.trim() |> String.split(~r/\s+/) do
          [ahead, behind] -> {to_int(ahead), to_int(behind)}
          _ -> {0, 0}
        end

      _ ->
        {0, 0}
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc """
  Extracts a pull/merge-request URL from push output, or `nil`.

  Public because this parses another program's human-facing text — the format is
  not ours and can change, so it is pinned by tests against real output.
  """
  @spec pr_url(String.t()) :: String.t() | nil
  def pr_url(output) do
    Enum.find_value(@pr_url_patterns, fn re ->
      case Regex.run(re, output) do
        [url] -> String.trim_trailing(url, ".")
        _ -> nil
      end
    end)
  end

  @doc """
  Builds a "open a PR for this branch" URL from `origin`, or `nil` when the
  remote is not an http(s)/ssh forge URL.

  Derived, not printed: once a branch exists on the remote the forge stops
  offering the link, but the user still wants somewhere to click.
  """
  @spec compare_url(String.t(), String.t()) :: String.t() | nil
  def compare_url(dir, branch) do
    with {remote, 0} <- run(dir, ["remote", "get-url", "origin"]),
         {:ok, base} <- https_base(String.trim(remote)) do
      "#{base}/compare/#{URI.encode(branch)}?expand=1"
    else
      _ -> nil
    end
  end

  # git@host:owner/repo.git and https://host/owner/repo.git both become
  # https://host/owner/repo.
  defp https_base("git@" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [host, path] -> {:ok, "https://#{host}/#{strip_git(path)}"}
      _ -> :error
    end
  end

  defp https_base("https://" <> _ = url), do: {:ok, strip_git(url)}
  defp https_base("http://" <> _ = url), do: {:ok, strip_git(url)}
  defp https_base(_), do: :error

  defp strip_git(path), do: String.replace_suffix(path, ".git", "")

  defp failure(summary, output) do
    case String.trim(output) do
      "" -> summary
      text -> "#{summary}:\n#{text}"
    end
  end

  defp run(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 1}
  end
end
