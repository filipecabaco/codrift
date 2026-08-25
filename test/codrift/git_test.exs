defmodule Codrift.GitTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Git
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  # Codrift.Git shells out to plain `git`, so the repositories under test need an
  # identity of their own — GitRepo passes one per command, which does not reach
  # commits made by the code being tested.
  defp identify!(dir) do
    GitRepo.git(dir, ["config", "user.email", "test@test.com"])
    GitRepo.git(dir, ["config", "user.name", "Test"])
    GitRepo.git(dir, ["config", "commit.gpgsign", "false"])
    dir
  end

  # A bare repo on disk stands in for the forge: enough for real pushes, fetches
  # and upstream tracking without a network.
  defp with_remote!(tmp_dir) do
    remote = Path.join(tmp_dir, "remote.git")
    File.mkdir_p!(remote)
    System.cmd("git", ["init", "--bare", "--initial-branch=main", remote], stderr_to_stdout: true)

    repo = GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"file.txt" => "one\n"})
    identify!(repo)
    GitRepo.git(repo, ["branch", "-M", "main"])
    GitRepo.git(repo, ["remote", "add", "origin", remote])
    GitRepo.git(repo, ["push", "-u", "origin", "main"])
    {repo, remote}
  end

  describe "commit/2" do
    test "stages everything and commits", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"a.txt" => "one\n"}))
      File.write!(Path.join(repo, "a.txt"), "two\n")
      File.write!(Path.join(repo, "new.txt"), "fresh\n")

      assert {:ok, %{"sha" => sha, "branch" => branch}} = Git.commit(repo, "a real message")
      assert is_binary(sha) and sha != ""
      assert is_binary(branch)

      # Both the modified and the untracked file went in — `add -A`, as documented.
      {out, 0} = GitRepo.git(repo, ["show", "--name-only", "--format=", "HEAD"])
      assert out =~ "a.txt"
      assert out =~ "new.txt"
      assert {"", 0} = GitRepo.git(repo, ["status", "--porcelain"])
    end

    test "refuses an empty message rather than writing a nameless commit", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"a.txt" => "one\n"}))
      File.write!(Path.join(repo, "a.txt"), "two\n")

      assert {:error, message} = Git.commit(repo, "   ")
      assert message =~ "message is required"
    end

    test "says so when there is nothing to commit", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init_with!(Path.join(tmp_dir, "repo"), %{"a.txt" => "one\n"}))

      assert {:error, message} = Git.commit(repo, "nothing here")
      assert message =~ "nothing to commit"
    end

    test "reports a directory that is not a repository", %{tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      assert {:error, message} = Git.commit(plain, "msg")
      assert message =~ "not a git repository"
    end
  end

  describe "fetch/1 and push/1" do
    test "push sets upstream and fetch sees what the remote gained", %{tmp_dir: tmp_dir} do
      {repo, remote} = with_remote!(tmp_dir)

      GitRepo.git(repo, ["checkout", "-b", "feature"])
      File.write!(Path.join(repo, "file.txt"), "two\n")
      {:ok, _} = Git.commit(repo, "on the feature branch")

      assert {:ok, %{"branch" => "feature"}} = Git.push(repo)

      # Upstream is now set, which is what makes rebase/ahead-behind work later.
      {out, 0} =
        GitRepo.git(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])

      assert String.trim(out) == "origin/feature"
      assert {out, 0} = System.cmd("git", ["branch", "--list"], cd: remote)
      assert out =~ "feature"

      assert {:ok, %{"output" => _}} = Git.fetch(repo)
    end

    test "info reports drift from the upstream", %{tmp_dir: tmp_dir} do
      {repo, _remote} = with_remote!(tmp_dir)

      File.write!(Path.join(repo, "file.txt"), "local change\n")
      {:ok, _} = Git.commit(repo, "one ahead")

      assert %{"branch" => "main", "ahead" => 1, "behind" => 0, "dirty" => false} = Git.info(repo)
    end

    test "info returns nil for a directory that is not a repository", %{tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)
      assert Git.info(plain) == nil
    end
  end

  describe "rebase/1" do
    test "replays local work on top of the upstream", %{tmp_dir: tmp_dir} do
      {repo, remote} = with_remote!(tmp_dir)

      # Someone else pushes to main via a second clone.
      other = Path.join(tmp_dir, "other")
      System.cmd("git", ["clone", remote, other], stderr_to_stdout: true)
      identify!(other)
      File.write!(Path.join(other, "theirs.txt"), "from elsewhere\n")
      GitRepo.commit!(other, "their work")
      GitRepo.git(other, ["push", "origin", "main"])

      # Meanwhile we commit locally, then rebase onto what they pushed.
      File.write!(Path.join(repo, "mine.txt"), "my work\n")
      {:ok, _} = Git.commit(repo, "my work")
      {:ok, _} = Git.fetch(repo)

      assert {:ok, %{"onto" => "origin/main"}} = Git.rebase(repo)

      assert File.exists?(Path.join(repo, "theirs.txt"))
      assert File.exists?(Path.join(repo, "mine.txt"))
      assert %{"ahead" => 1, "behind" => 0} = Git.info(repo)
    end

    test "a conflict aborts and leaves the tree as it was", %{tmp_dir: tmp_dir} do
      {repo, remote} = with_remote!(tmp_dir)

      other = Path.join(tmp_dir, "other")
      System.cmd("git", ["clone", remote, other], stderr_to_stdout: true)
      identify!(other)
      File.write!(Path.join(other, "file.txt"), "theirs\n")
      GitRepo.commit!(other, "their edit")
      GitRepo.git(other, ["push", "origin", "main"])

      File.write!(Path.join(repo, "file.txt"), "mine\n")
      {:ok, _} = Git.commit(repo, "my edit")
      {:ok, _} = Git.fetch(repo)

      assert {:error, message} = Git.rebase(repo)
      assert message =~ "failed"

      # Aborted: still on our own commit, and not stuck mid-rebase.
      assert File.read!(Path.join(repo, "file.txt")) == "mine\n"
      refute File.dir?(Path.join([repo, ".git", "rebase-merge"]))
      refute File.dir?(Path.join([repo, ".git", "rebase-apply"]))
    end
  end

  describe "pr_url/1" do
    test "finds GitHub's create-a-PR link in push output" do
      output = """
      remote: Resolving deltas: 100% (3/3), done.
      remote:
      remote: Create a pull request for 'feature' on GitHub by visiting:
      remote:      https://github.com/owner/repo/pull/new/feature
      remote:
      To github.com:owner/repo.git
       * [new branch]      feature -> feature
      """

      assert Git.pr_url(output) == "https://github.com/owner/repo/pull/new/feature"
    end

    test "finds GitLab's merge-request link" do
      output = """
      remote: To create a merge request for topic, visit:
      remote:   https://gitlab.com/owner/repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=topic
      """

      assert Git.pr_url(output) =~ "gitlab.com"
      assert Git.pr_url(output) =~ "merge_requests/new"
    end

    test "returns nil when the forge printed no link" do
      assert Git.pr_url("Everything up-to-date\n") == nil
    end
  end

  describe "compare_url/2" do
    test "derives an https compare URL from an ssh remote", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init!(Path.join(tmp_dir, "repo")))
      GitRepo.git(repo, ["remote", "add", "origin", "git@github.com:owner/repo.git"])

      assert Git.compare_url(repo, "my-branch") ==
               "https://github.com/owner/repo/compare/my-branch?expand=1"
    end

    test "derives one from an https remote, dropping the .git suffix", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init!(Path.join(tmp_dir, "repo")))
      GitRepo.git(repo, ["remote", "add", "origin", "https://github.com/owner/repo.git"])

      assert Git.compare_url(repo, "topic") ==
               "https://github.com/owner/repo/compare/topic?expand=1"
    end

    test "returns nil for a remote that is not a forge URL", %{tmp_dir: tmp_dir} do
      repo = identify!(GitRepo.init!(Path.join(tmp_dir, "repo")))
      GitRepo.git(repo, ["remote", "add", "origin", "/srv/mirrors/repo.git"])

      assert Git.compare_url(repo, "topic") == nil
    end
  end
end
