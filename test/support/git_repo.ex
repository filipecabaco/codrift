defmodule Codrift.Test.GitRepo do
  @moduledoc """
  Git fixtures for tests that need a real repository (diff, worktrees, tree).

  Identity and signing are forced at the command level: a global
  `commit.gpgsign = true` otherwise prompts for a passphrase and the test hangs
  until the ExUnit timeout.
  """

  # -c beats ~/.gitconfig.
  @overrides [
    "-c",
    "user.email=test@test.com",
    "-c",
    "user.name=Test",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "tag.gpgsign=false"
  ]

  @doc "Runs `git <args>` in `dir` with the test identity. Returns `{output, exit_code}`."
  def git(dir, args), do: System.cmd("git", @overrides ++ args, cd: dir, stderr_to_stdout: true)

  @doc "Initialises an empty repository with one empty commit, so HEAD exists."
  def init!(dir) do
    File.mkdir_p!(dir)
    git(dir, ["init"])
    isolate!(dir)
    commit!(dir, "initial", allow_empty: true)
    dir
  end

  # A developer's global gitignore must not change what these tests see. Codrift
  # writes `.claude/settings.json` into every worktree it creates, and a machine
  # whose `~/.gitignore_global` covers `.claude` hides a file CI reports — which
  # is exactly how a bug in worktree dirty-detection passed locally and failed
  # in CI.
  defp isolate!(dir), do: git(dir, ["config", "core.excludesFile", "/dev/null"])

  @doc "Stages everything in `dir` and commits it."
  def commit!(dir, message, opts \\ []) do
    if opts[:allow_empty] do
      {_, 0} = git(dir, ["commit", "--allow-empty", "-m", message])
    else
      git(dir, ["add", "-A"])
      {_, 0} = git(dir, ["commit", "-m", message])
    end

    :ok
  end

  @doc "Initialises a repository whose first commit contains `files` (`%{path => content}`)."
  def init_with!(dir, files) do
    File.mkdir_p!(dir)
    git(dir, ["init"])
    isolate!(dir)

    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    commit!(dir, "initial")
    dir
  end
end
