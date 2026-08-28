defmodule Codrift.BundledCLITest do
  @moduledoc """
  The `codrift` command is a symlink into `Codrift.app`, not a second install.

  Both installers point at one path inside the bundle — `Contents/MacOS/desktop`
  — and nothing type-checks that path. It is decided in three places that move
  independently (the release name in `mix.exs`, Tauri's `externalBin`, and the
  two installers), and if they disagree the failure is a broken `codrift` on a
  user's PATH, discovered after a release rather than in CI.

  Why the symlink exists at all: the sidecar it points at is a Burrito-wrapped
  release of this same application, so shipping a separate `codrift-cli` tarball
  meant downloading the same ~15 MB of BEAM twice. See `Codrift.start/2`.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  # The name Tauri gives the sidecar inside the bundle, which is the release
  # name from mix.exs — ex_tauri wraps `burrito_out/desktop-<triple>` and Tauri
  # strips the triple when bundling.
  @sidecar "desktop"
  @in_bundle "Codrift.app/Contents/MacOS/#{@sidecar}"

  defp read(path), do: File.read!(Path.join(@repo_root, path))

  describe "the sidecar the installers point at" do
    test "is the release mix.exs builds" do
      assert read("mix.exs") =~ ~r/^\s*#{@sidecar}: \[/m,
             "the installers link `codrift` to Contents/MacOS/#{@sidecar}; " <>
               "renaming the release renames that file"
    end

    test "is the binary Tauri bundles" do
      config = Jason.decode!(read("src-tauri/tauri.conf.json"))

      assert ["../burrito_out/#{@sidecar}"] == config["bundle"]["externalBin"],
             "Tauri names the bundled sidecar after this entry"
    end
  end

  describe "Homebrew cask" do
    setup do: %{cask: read("Casks/codrift.rb")}

    test "puts the command on PATH out of the bundle", %{cask: cask} do
      assert cask =~ ~s(binary "\#{appdir}/#{@in_bundle}", target: "codrift")
    end

    # The cask's own caveats tell users to run `codrift mcp install`. Depending
    # on a formula for that is what shipped the same release twice.
    test "does not pull in a second copy of the release", %{cask: cask} do
      refute cask =~ "depends_on formula:"
      refute File.exists?(Path.join(@repo_root, "Formula/codrift-cli.rb"))
    end
  end

  describe "install.sh" do
    setup do: %{sh: read("install.sh")}

    test "links into the bundle on macOS", %{sh: sh} do
      assert sh =~ ~s(SIDECAR="${INSTALLED_APP}/Contents/MacOS/#{@sidecar}")
      assert sh =~ ~s(ln -sf "${SIDECAR}" "${BIN_DIR}/codrift")
    end

    # INSTALLED_APP is set only by the Darwin leg, and it is what routes past
    # the tarball download. Unset (Linux) it must fall through, because an
    # AppImage is one squashfs file with no sidecar to link to.
    test "falls back to the tarball where there is no bundle to link into", %{sh: sh} do
      assert sh =~ ~s(if [ -n "${INSTALLED_APP:-}" ] && link_bundled_cli; then)
      assert sh =~ "codrift-cli-.*${CLI_TARGET}\\.tar\\.gz$"
    end

    test "is byte-identical to the copy the website serves" do
      assert read("install.sh") == read("website/priv/static/install.sh")
    end
  end

  describe "release.yml" do
    test "still publishes the CLI tarball install.sh's Linux leg downloads" do
      assert read(".github/workflows/release.yml") =~
               ~S(dist/codrift-cli-${VERSION}-${{ matrix.cli_suffix }}.tar.gz)
    end
  end
end
