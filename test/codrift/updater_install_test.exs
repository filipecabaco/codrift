defmodule Codrift.UpdaterInstallTest do
  @moduledoc """
  `install_tarball/2` against real tarballs on disk — no network, no stubs.

  This is the most dangerous code in the app: it replaces the very tree the
  running process is executing out of. The design that makes that safe is
  "extract beside, then swap with two renames", and the property worth pinning
  is the one that holds when things go wrong — **a failed install leaves the
  working tree exactly as it was**. A truncated download, a differently-shaped
  archive or a killed process must never be able to produce a half-replaced
  install, because the thing left behind is what the user runs next.

  Every fixture here is a real gzipped tar built with `:erl_tar`, so the
  extraction path under test is the one that runs in production.
  """
  use ExUnit.Case, async: true

  alias Codrift.Updater

  @moduletag :tmp_dir

  # A mix release tarball has bin/, lib/ and releases/ at its root with no
  # wrapping directory — `verify_release_tree/1` looks for bin/codrift.
  defp build_tarball!(path, files) do
    staging = path <> ".build"
    File.rm_rf!(staging)

    entries =
      for {name, content} <- files do
        full = Path.join(staging, name)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        {String.to_charlist(name), String.to_charlist(full)}
      end

    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.rm_rf!(staging)
    path
  end

  defp release_tarball!(dir, marker \\ "new") do
    build_tarball!(Path.join(dir, "release.tar.gz"), [
      {"bin/codrift", "#!/bin/sh\necho #{marker}\n"},
      {"lib/app.beam", "beam-#{marker}"},
      {"releases/start_erl.data", "erts #{marker}"}
    ])
  end

  defp existing_install!(dir) do
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "bin", "codrift"]), "#!/bin/sh\necho old\n")
    File.write!(Path.join(dir, "old-only.txt"), "left over from the previous version")
    dir
  end

  describe "a good tarball" do
    test "replaces an existing install, and nothing of the old tree survives",
         %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      tarball = release_tarball!(tmp_dir)

      assert :ok = Updater.install_tarball(tarball, install)

      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo new"
      assert File.read!(Path.join(install, "lib/app.beam")) == "beam-new"

      # A swap, not a merge: a file only the old version had must be gone, or
      # the tree becomes an accumulation of every version ever installed.
      refute File.exists?(Path.join(install, "old-only.txt"))
    end

    test "installs into a directory that does not exist yet", %{tmp_dir: tmp_dir} do
      install = Path.join(tmp_dir, "fresh")
      tarball = release_tarball!(tmp_dir)

      assert :ok = Updater.install_tarball(tarball, install)
      assert File.regular?(Path.join([install, "bin", "codrift"]))
    end

    test "leaves no staging or backup directory behind", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      tarball = release_tarball!(tmp_dir)

      assert :ok = Updater.install_tarball(tarball, install)

      refute File.exists?(install <> ".new")
      refute File.exists?(install <> ".old")
    end

    test "succeeds twice in a row, so a repeated update is not a special case",
         %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))

      assert :ok = Updater.install_tarball(release_tarball!(tmp_dir, "first"), install)
      assert :ok = Updater.install_tarball(release_tarball!(tmp_dir, "second"), install)

      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo second"
    end

    test "cleans up a staging directory left by a previous crashed run",
         %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      # A process killed mid-extract leaves `<dir>.new` full of a partial tree.
      File.mkdir_p!(Path.join(install <> ".new", "bin"))
      File.write!(Path.join([install <> ".new", "bin", "junk"]), "partial")

      assert :ok = Updater.install_tarball(release_tarball!(tmp_dir), install)

      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo new"
      refute File.exists?(Path.join([install, "bin", "junk"]))
      refute File.exists?(install <> ".new")
    end

    test "removes a backup directory left by a previous crashed run", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      File.mkdir_p!(install <> ".old")
      File.write!(Path.join(install <> ".old", "ancient"), "two versions ago")

      assert :ok = Updater.install_tarball(release_tarball!(tmp_dir), install)
      refute File.exists?(install <> ".old")
    end
  end

  describe "a bad tarball leaves the working install alone" do
    test "an archive with no bin/codrift is rejected", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))

      wrong =
        build_tarball!(Path.join(tmp_dir, "wrong.tar.gz"), [
          {"some-other-tree/bin/codrift", "#!/bin/sh\n"},
          {"README.md", "not a release"}
        ])

      assert {:error, message} = Updater.install_tarball(wrong, install)
      assert message =~ "bin/codrift"

      # The whole point: the install the user runs next is untouched.
      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo old"
      assert File.exists?(Path.join(install, "old-only.txt"))
      refute File.exists?(install <> ".new")
    end

    test "a truncated download is rejected", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      tarball = release_tarball!(tmp_dir)

      # Half a gzip stream is exactly what a dropped connection leaves.
      full = File.read!(tarball)
      truncated = Path.join(tmp_dir, "truncated.tar.gz")
      File.write!(truncated, binary_part(full, 0, div(byte_size(full), 2)))

      assert {:error, message} = Updater.install_tarball(truncated, install)
      assert message =~ "could not unpack"

      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo old"
      refute File.exists?(install <> ".new")
    end

    test "a file that is not an archive at all is rejected", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      garbage = Path.join(tmp_dir, "garbage.tar.gz")
      File.write!(garbage, "this is not a tarball")

      assert {:error, _} = Updater.install_tarball(garbage, install)
      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo old"
    end

    test "a tarball that is not there at all is rejected", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))

      assert {:error, _} =
               Updater.install_tarball(Path.join(tmp_dir, "never-downloaded.tar.gz"), install)

      assert File.read!(Path.join([install, "bin", "codrift"])) =~ "echo old"
    end

    test "an empty archive is rejected rather than installing nothing", %{tmp_dir: tmp_dir} do
      install = existing_install!(Path.join(tmp_dir, "install"))
      empty = build_tarball!(Path.join(tmp_dir, "empty.tar.gz"), [])

      assert {:error, message} = Updater.install_tarball(empty, install)
      assert message =~ "bin/codrift"
      assert File.exists?(Path.join(install, "old-only.txt"))
    end
  end
end
