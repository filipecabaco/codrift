defmodule Codrift.DiffTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Diff
  alias Codrift.Diff.{FileDiff, Line}

  @sample_patch """
  diff --git a/lib/foo.ex b/lib/foo.ex
  index abc1234..def5678 100644
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -1,5 +1,6 @@
   defmodule Foo do
  -  def old_fun, do: :old
  +  def new_fun, do: :new
  +  def extra_fun, do: :extra
     def unchanged, do: :ok
   end
  diff --git a/lib/bar.ex b/lib/bar.ex
  index 0000000..1111111 100644
  --- /dev/null
  +++ b/lib/bar.ex
  @@ -0,0 +1,3 @@
  +defmodule Bar do
  +  def hello, do: :world
  +end
  """

  describe "parse/1" do
    test "returns one FileDiff per changed file" do
      assert [%FileDiff{}, %FileDiff{}] = Diff.parse(@sample_patch)
    end

    test "extracts file paths" do
      [foo, bar] = Diff.parse(@sample_patch)
      assert foo.path == "lib/foo.ex"
      assert bar.path == "lib/bar.ex"
    end

    test "marks new file with /dev/null old_path" do
      [_, bar] = Diff.parse(@sample_patch)
      assert bar.old_path == "/dev/null"
    end

    test "counts additions and deletions" do
      [foo, bar] = Diff.parse(@sample_patch)
      assert foo.additions == 2
      assert foo.deletions == 1
      assert bar.additions == 3
      assert bar.deletions == 0
    end

    test "parses hunk header coordinates" do
      [%{hunks: [hunk]} | _] = Diff.parse(@sample_patch)
      assert hunk.old_start == 1
      assert hunk.old_count == 5
      assert hunk.new_start == 1
      assert hunk.new_count == 6
    end

    test "classifies lines correctly" do
      [%{hunks: [hunk]} | _] = Diff.parse(@sample_patch)

      assert [
               %Line{type: :context, content: "defmodule Foo do"},
               %Line{type: :remove, content: "  def old_fun, do: :old"},
               %Line{type: :add, content: "  def new_fun, do: :new"},
               %Line{type: :add, content: "  def extra_fun, do: :extra"},
               %Line{type: :context, content: "  def unchanged, do: :ok"},
               %Line{type: :context, content: "end"}
             ] = hunk.lines
    end

    test "returns empty list for empty patch" do
      assert [] = Diff.parse("")
    end

    test "handles multiple hunks in one file" do
      patch = """
      diff --git a/big.ex b/big.ex
      index aaa..bbb 100644
      --- a/big.ex
      +++ b/big.ex
      @@ -1,3 +1,3 @@
       line1
      -old2
      +new2
       line3
      @@ -10,3 +10,3 @@
       line10
      -old11
      +new11
       line12
      """

      [%FileDiff{hunks: hunks}] = Diff.parse(patch)
      assert length(hunks) == 2
    end
  end

  describe "generate/2" do
    @moduletag :tmp_dir

    defp init_git_repo(dir) do
      System.cmd("git", ["init"], cd: dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: dir)
    end

    defp git_commit(dir, message) do
      System.cmd("git", ["add", "-A"], cd: dir)
      System.cmd("git", ["commit", "-m", message], cd: dir)
    end

    test "returns {:ok, []} when there are no changes", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "file.ex"), "content\n")
      git_commit(dir, "initial")

      assert {:ok, []} = Diff.generate(dir)
    end

    test "returns unstaged changes", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "file.ex"), "original\n")
      git_commit(dir, "initial")

      File.write!(Path.join(dir, "file.ex"), "modified\n")

      assert {:ok, [%FileDiff{path: "file.ex", additions: 1, deletions: 1}]} = Diff.generate(dir)
    end

    test "returns staged changes with staged: true", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "file.ex"), "original\n")
      git_commit(dir, "initial")

      File.write!(Path.join(dir, "file.ex"), "staged change\n")
      System.cmd("git", ["add", "file.ex"], cd: dir)

      assert {:ok, [%FileDiff{path: "file.ex"}]} = Diff.generate(dir, staged: true)
    end

    test "returns diff between two refs", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "file.ex"), "v1\n")
      git_commit(dir, "v1")

      File.write!(Path.join(dir, "file.ex"), "v2\n")
      git_commit(dir, "v2")

      assert {:ok, [%FileDiff{additions: 1, deletions: 1}]} =
               Diff.generate(dir, from: "HEAD~1", to: "HEAD")
    end

    test "limits diff to specified paths", %{tmp_dir: dir} do
      init_git_repo(dir)
      File.write!(Path.join(dir, "a.ex"), "a\n")
      File.write!(Path.join(dir, "b.ex"), "b\n")
      git_commit(dir, "initial")

      File.write!(Path.join(dir, "a.ex"), "a modified\n")
      File.write!(Path.join(dir, "b.ex"), "b modified\n")

      assert {:ok, [%FileDiff{path: "a.ex"}]} = Diff.generate(dir, paths: ["a.ex"])
    end

    test "returns error for an invalid ref", %{tmp_dir: dir} do
      init_git_repo(dir)
      assert {:error, _} = Diff.generate(dir, from: "nonexistent-ref-xyz", to: "HEAD")
    end
  end
end
