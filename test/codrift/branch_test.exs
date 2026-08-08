defmodule Codrift.BranchTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Branch
  alias Codrift.Initiative
  alias Codrift.Initiative.Store
  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  describe "name/1" do
    test "uses the tracker item id when the initiative came from one" do
      initiative = %Initiative{
        Initiative.new("Add field to v0, v1 and system controllers")
        | integration: %{service: "linear", item_id: "REAL-949", url: nil}
      }

      assert Branch.name(initiative) == "codrift/real-949"
    end

    test "falls back to the initiative name" do
      assert Branch.name(Initiative.new("Move out of ECB encryption")) ==
               "codrift/move-out-of-ecb-encryption"
    end

    test "is filesystem-safe and bounded" do
      name = Branch.name(Initiative.new(String.duplicate("Very Long Name ", 20)))

      assert String.starts_with?(name, "codrift/")
      assert String.length(name) <= 68
      refute name =~ ~r/[^a-z0-9\/-]/
    end
  end

  describe "ensure/2" do
    test "creates the branch and checks it out", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))

      assert {:ok, "codrift/real-1"} = Branch.ensure(repo, "codrift/real-1")
      assert Branch.current(repo) == "codrift/real-1"
    end

    test "is idempotent once checked out", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))

      assert {:ok, _} = Branch.ensure(repo, "codrift/real-1")
      assert {:ok, "codrift/real-1"} = Branch.ensure(repo, "codrift/real-1")
    end

    test "switches back to an existing branch instead of recreating it", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))

      {:ok, _} = Branch.ensure(repo, "codrift/real-1")
      {_, 0} = GitRepo.git(repo, ["checkout", "-b", "other"])

      assert {:ok, "codrift/real-1"} = Branch.ensure(repo, "codrift/real-1")
    end

    test "refuses to switch a dirty working tree", %{tmp_dir: tmp_dir} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      File.write!(Path.join(repo, "wip.txt"), "uncommitted")

      assert {:error, reason} = Branch.ensure(repo, "codrift/real-1")
      assert reason =~ "uncommitted changes"
      refute Branch.current(repo) == "codrift/real-1"
    end

    test "rejects a directory that is not a repository", %{tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      assert {:error, reason} = Branch.ensure(plain, "codrift/real-1")
      assert reason =~ "not a git repository"
    end
  end

  describe "Store.branch_all/2" do
    setup %{tmp_dir: tmp_dir} do
      store =
        start_supervised!(
          {Store,
           path: Path.join(tmp_dir, "initiatives.json"), name: nil, context_dir_base: tmp_dir}
        )

      {:ok, store: store}
    end

    test "branches every git directory and reports the rest", %{tmp_dir: tmp_dir, store: store} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      dirty = GitRepo.init!(Path.join(tmp_dir, "dirty"))
      File.write!(Path.join(dirty, "wip.txt"), "uncommitted")

      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      {:ok, initiative} = Store.create("Move out of ECB encryption", [], store)
      for dir <- [repo, dirty, plain], do: Store.add_dir(initiative.id, dir, [], store)

      assert {:ok, result} = Store.branch_all(initiative.id, store)
      assert result.branch == "codrift/move-out-of-ecb-encryption"
      assert result.switched == [repo]

      assert [%{dir: ^dirty, reason: dirty_reason}, %{dir: ^plain, reason: plain_reason}] =
               Enum.sort_by(result.skipped, & &1.dir)

      assert dirty_reason =~ "uncommitted changes"
      assert plain_reason =~ "not a git repository"

      assert Branch.current(repo) == "codrift/move-out-of-ecb-encryption"

      {:ok, reloaded} = Store.get(initiative.id, store)
      branches = Map.new(reloaded.dirs, &{&1.path, &1.branch})
      assert branches[repo] == "codrift/move-out-of-ecb-encryption"
      assert branches[dirty] == nil
    end

    test "records the branch in initiative.md", %{tmp_dir: tmp_dir, store: store} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      {:ok, initiative} = Store.create("Ship it", [], store)
      Store.add_dir(initiative.id, repo, [], store)

      {:ok, _} = Store.branch_all(initiative.id, store)
      _ = Store.get(initiative.id, store)

      assert {:ok, md} = File.read(Path.join(tmp_dir, "#{initiative.id}/initiative.md"))
      assert md =~ "branch `codrift/ship-it`"
    end
  end

  describe "Store.toggle_dir_branch/3" do
    setup %{tmp_dir: tmp_dir} do
      store =
        start_supervised!(
          {Store,
           path: Path.join(tmp_dir, "initiatives.json"), name: nil, context_dir_base: tmp_dir}
        )

      {:ok, store: store}
    end

    test "turning it off stops tracking but leaves the checkout alone", %{
      tmp_dir: tmp_dir,
      store: store
    } do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      {:ok, initiative} = Store.create("Ship it", [], store)
      Store.add_dir(initiative.id, repo, [], store)

      assert {:ok, on} = Store.toggle_dir_branch(initiative.id, repo, store)
      assert [%{branch: "codrift/ship-it"}] = on.dirs

      assert {:ok, off} = Store.toggle_dir_branch(initiative.id, repo, store)
      assert [%{branch: nil}] = off.dirs
      assert Branch.current(repo) == "codrift/ship-it"
    end

    test "surfaces why a directory could not switch", %{tmp_dir: tmp_dir, store: store} do
      repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
      File.write!(Path.join(repo, "wip.txt"), "uncommitted")

      {:ok, initiative} = Store.create("Ship it", [], store)
      Store.add_dir(initiative.id, repo, [], store)

      assert {:error, reason} = Store.toggle_dir_branch(initiative.id, repo, store)
      assert reason =~ "uncommitted changes"
    end

    test "returns :not_found for an unknown directory", %{store: store} do
      {:ok, initiative} = Store.create("Ship it", [], store)

      assert {:error, :not_found} = Store.toggle_dir_branch(initiative.id, "/nope", store)
    end
  end
end
