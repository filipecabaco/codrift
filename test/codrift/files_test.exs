defmodule Codrift.FilesTest do
  @moduledoc false
  use ExUnit.Case, async: true

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
end
