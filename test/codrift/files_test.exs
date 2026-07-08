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
end
