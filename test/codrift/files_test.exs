defmodule Codrift.FilesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Test.GitRepo

  @moduletag :tmp_dir

  describe "list_relative/1" do
    test "lists files recursively under a directory", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "a.txt"), "hi")
      File.mkdir_p!(Path.join(tmp, "sub"))
      File.write!(Path.join([tmp, "sub", "b.ex"]), "x")

      files = Codrift.Files.list_relative(tmp)
      assert "a.txt" in files
      assert "sub/b.ex" in files
    end
  end

  describe "git_repo?/1" do
    # ExUnit's tmp_dir lives inside this repository, so a directory with no git
    # ancestor has to be created outside it.
    test "is false for a directory with no git ancestor" do
      plain =
        Path.join(System.tmp_dir!(), "codrift-files-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf!(plain) end)

      refute Codrift.Files.in_git_repo?(plain)
    end

    test "is true for a repository root and for directories inside it", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)
      nested = Path.join([repo, "lib", "deep"])
      File.mkdir_p!(nested)

      assert Codrift.Files.in_git_repo?(repo)
      assert Codrift.Files.in_git_repo?(nested)
    end
  end

  describe "read_within/2" do
    test "reads a file inside an allowed directory", %{tmp_dir: tmp} do
      path = Path.join(tmp, "f.txt")
      File.write!(path, "content")
      assert {:ok, "content"} = Codrift.Files.read_within([tmp], path)
    end

    test "refuses a path outside the allowed directories", %{tmp_dir: tmp} do
      assert {:error, :forbidden} = Codrift.Files.read_within([tmp], "/etc/hosts")
    end

    test "refuses a sibling path that merely shares a prefix", %{tmp_dir: tmp} do
      allowed = Path.join(tmp, "project")
      File.mkdir_p!(allowed)
      sibling = Path.join(tmp, "project-secrets")
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "leak.txt"), "nope")

      assert {:error, :forbidden} =
               Codrift.Files.read_within([allowed], Path.join(sibling, "leak.txt"))
    end

    test "refuses a directory target", %{tmp_dir: tmp} do
      assert {:error, :not_a_file} = Codrift.Files.read_within([tmp], tmp)
    end
  end

  describe "write_within/3" do
    test "writes a file inside an allowed directory", %{tmp_dir: tmp} do
      path = Path.join(tmp, "out.txt")
      assert :ok = Codrift.Files.write_within([tmp], path, "hello")
      assert File.read!(path) == "hello"
    end

    test "refuses to write outside the allowed directories", %{tmp_dir: tmp} do
      assert {:error, :forbidden} = Codrift.Files.write_within([tmp], "/tmp/evil.txt", "x")
    end

    test "refuses to overwrite a directory", %{tmp_dir: tmp} do
      assert {:error, :not_a_file} = Codrift.Files.write_within([tmp], tmp, "x")
    end
  end

  describe "symlink escapes" do
    setup %{tmp_dir: tmp} do
      allowed = Path.join(tmp, "allowed")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(allowed)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "secret")
      %{allowed: allowed, outside: outside}
    end

    test "refuses reading through a symlinked file that points outside",
         %{allowed: allowed, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(allowed, "link.txt"))

      assert {:error, :forbidden} =
               Codrift.Files.read_within([allowed], Path.join(allowed, "link.txt"))
    end

    test "refuses reading through a symlinked directory that points outside",
         %{allowed: allowed, outside: outside} do
      File.ln_s!(outside, Path.join(allowed, "sneaky"))

      assert {:error, :forbidden} =
               Codrift.Files.read_within([allowed], Path.join(allowed, "sneaky/secret.txt"))
    end

    test "refuses writing through a symlink that points outside",
         %{allowed: allowed, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(allowed, "link.txt"))

      assert {:error, :forbidden} =
               Codrift.Files.write_within([allowed], Path.join(allowed, "link.txt"), "pwn")

      assert File.read!(Path.join(outside, "secret.txt")) == "secret"
    end

    test "allows a relative symlink that stays inside the allowed root",
         %{allowed: allowed} do
      File.write!(Path.join(allowed, "real.txt"), "fine")
      File.ln_s!("real.txt", Path.join(allowed, "alias.txt"))

      assert {:ok, "fine"} =
               Codrift.Files.read_within([allowed], Path.join(allowed, "alias.txt"))
    end

    test "allows files under an allowed root that is itself behind a symlink",
         %{tmp_dir: tmp, allowed: allowed} do
      File.write!(Path.join(allowed, "real.txt"), "fine")
      linked_root = Path.join(tmp, "root-link")
      File.ln_s!(allowed, linked_root)

      assert {:ok, "fine"} =
               Codrift.Files.read_within([linked_root], Path.join(linked_root, "real.txt"))
    end

    test "realpath rejects symlink loops", %{allowed: allowed} do
      a = Path.join(allowed, "a")
      b = Path.join(allowed, "b")
      File.ln_s!(b, a)
      File.ln_s!(a, b)

      assert {:error, :eloop} = Codrift.Files.realpath(Path.join(a, "x.txt"))
    end
  end

  describe "preview/1" do
    test "returns the README when the directory has one", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "README.md"), "# Hello")
      File.write!(Path.join(tmp, "mix.exs"), "x")

      assert %{"kind" => "readme", "name" => "README.md", "content" => "# Hello", "dir" => ^tmp} =
               Codrift.Files.preview(tmp)
    end

    test "finds a README whatever its casing or extension", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "readme.txt"), "plain")

      assert %{"kind" => "readme", "name" => "readme.txt"} = Codrift.Files.preview(tmp)
    end

    test "prefers a single deterministic README when several exist", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "README.md"), "md")
      File.write!(Path.join(tmp, "README.txt"), "txt")

      assert %{"name" => "README.md"} = Codrift.Files.preview(tmp)
    end

    test "does not mistake a README-ish name for a README", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "readme_generator.ex"), "x")

      assert %{"kind" => "tree"} = Codrift.Files.preview(tmp)
    end

    test "falls back to a shallow tree with parents directly above children",
         %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "lib", "codrift", "web"]))
      File.mkdir_p!(Path.join(tmp, "assets"))
      File.write!(Path.join(tmp, "mix.exs"), "x")
      File.write!(Path.join([tmp, "lib", "agent.ex"]), "x")
      File.write!(Path.join([tmp, "lib", "codrift", "web", "router.ex"]), "x")
      File.write!(Path.join([tmp, "assets", "app.css"]), "x")

      assert %{"kind" => "tree", "entries" => entries, "truncated" => false} =
               Codrift.Files.preview(tmp)

      assert Enum.map(entries, & &1["path"]) == [
               "assets",
               "assets/app.css",
               "lib",
               "lib/codrift",
               "lib/agent.ex",
               "mix.exs"
             ]

      assert Enum.map(entries, & &1["dir"]) == [true, false, true, true, false, false]
      assert Enum.map(entries, & &1["depth"]) == [0, 1, 0, 1, 1, 0]
    end

    test "keeps a deep file's ancestors rather than dropping the file entirely",
         %{tmp_dir: tmp} do
      File.mkdir_p!(Path.join([tmp, "a", "b", "c", "d"]))
      File.write!(Path.join([tmp, "a", "b", "c", "d", "deep.ex"]), "x")

      assert %{"kind" => "tree", "entries" => entries} = Codrift.Files.preview(tmp)
      assert Enum.map(entries, & &1["path"]) == ["a", "a/b"]
    end

    test "reports truncation once the tree runs past the preview limit", %{tmp_dir: tmp} do
      Enum.each(1..80, &File.write!(Path.join(tmp, "f#{&1}.txt"), "x"))

      assert %{"kind" => "tree", "entries" => entries, "truncated" => true} =
               Codrift.Files.preview(tmp)

      assert length(entries) == 60
    end

    test "says empty rather than tree for a directory with nothing in it", %{tmp_dir: tmp} do
      empty = Path.join(tmp, "empty")
      File.mkdir_p!(empty)

      assert %{"kind" => "empty", "entries" => [], "dir" => ^empty} = Codrift.Files.preview(empty)
    end
  end

  describe "inspect_path/1" do
    test "reports a repository root as worktree-capable", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)

      assert %{
               "exists" => true,
               "dir" => true,
               "git" => true,
               "git_root" => true,
               "path" => ^repo
             } =
               Codrift.Files.inspect_path(repo)
    end

    test "a directory inside a repo is git, but not a worktree root", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "repo")
      GitRepo.init!(repo)
      nested = Path.join(repo, "lib")
      File.mkdir_p!(nested)

      assert %{"git" => true, "git_root" => false} = Codrift.Files.inspect_path(nested)
    end

    test "expands ~ and trims whitespace" do
      assert %{"path" => path} = Codrift.Files.inspect_path("  ~/  ")
      assert path == System.user_home!()
    end

    test "reports a missing path as absent" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "codrift-does-not-exist-#{System.unique_integer([:positive])}"
        )

      assert %{"exists" => false, "dir" => false, "git_root" => false} =
               Codrift.Files.inspect_path(missing)
    end
  end
end
