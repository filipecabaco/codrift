defmodule Codrift.UpdaterTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Codrift.Updater

  @repo_root Path.expand("../..", __DIR__)
  @release_yml Path.join(@repo_root, ".github/workflows/release.yml")
  @install_sh Path.join(@repo_root, "install.sh")

  describe "cli_asset/2" do
    test "builds the codrift-cli-<version>-<target>.tar.gz asset name" do
      assert Updater.cli_asset("1.2.3", "x86_64-linux-gnu") ==
               "codrift-cli-1.2.3-x86_64-linux-gnu.tar.gz"
    end

    test "matches the asset naming produced by release.yml" do
      yml = File.read!(@release_yml)

      # The "Collect release assets" step defines the published asset name; if it
      # changes, the updater must change with it (and vice versa).
      assert yml =~ ~S(codrift-cli-${VERSION}-${{ matrix.cli_suffix }}.tar.gz),
             "release.yml no longer names CLI tarballs codrift-cli-<version>-<suffix>.tar.gz; " <>
               "update Codrift.Updater.cli_asset/2 to match"
    end

    test "matches the asset pattern install.sh greps for" do
      assert File.read!(@install_sh) =~ "codrift-cli-.*${CLI_TARGET}\\.tar\\.gz$"
    end

    test "every cli_suffix built by release.yml yields a well-formed asset name" do
      suffixes =
        @release_yml
        |> File.read!()
        |> then(&Regex.scan(~r/cli_suffix:\s*(\S+)/, &1, capture: :all_but_first))
        |> List.flatten()

      assert suffixes != [], "no cli_suffix entries found in release.yml"

      for suffix <- suffixes do
        assert Updater.cli_asset("0.1.0", suffix) == "codrift-cli-0.1.0-#{suffix}.tar.gz"
      end
    end
  end

  describe "desktop_asset/2" do
    # The names come from the Tauri bundler, not from us, so the updater matches
    # their shape instead of reconstructing them.
    @assets %{
      "Codrift_1.2.3_aarch64.dmg" => "https://example.test/arm.dmg",
      "Codrift_1.2.3_x64.dmg" => "https://example.test/intel.dmg",
      "Codrift_1.2.3_amd64.AppImage" => "https://example.test/linux.AppImage",
      "codrift-cli-1.2.3-aarch64-apple-darwin.tar.gz" => "https://example.test/cli.tar.gz"
    }

    test "picks the arm disk image on Apple silicon" do
      assert {:ok, {"Codrift_1.2.3_aarch64.dmg", "https://example.test/arm.dmg"}} =
               Updater.desktop_asset(@assets, "aarch64-apple-darwin")
    end

    test "picks the intel disk image on x86 macOS" do
      assert {:ok, {"Codrift_1.2.3_x64.dmg", "https://example.test/intel.dmg"}} =
               Updater.desktop_asset(@assets, "x86_64-apple-darwin")
    end

    test "picks the AppImage on Linux" do
      assert {:ok, {"Codrift_1.2.3_amd64.AppImage", _}} =
               Updater.desktop_asset(@assets, "x86_64-linux-gnu")
    end

    # An arm Linux release publishes no bundle today. Saying so beats
    # downloading an intel one and calling it an update.
    test "is an error when the release carries nothing for this platform" do
      assert :error = Updater.desktop_asset(@assets, "aarch64-linux-gnu")
      assert :error = Updater.desktop_asset(%{}, "aarch64-apple-darwin")
      assert :error = Updater.desktop_asset(@assets, "sparc-solaris")
    end

    # The CLI tarball is published in the same release and must never be
    # mistaken for the app bundle.
    test "never matches the CLI tarball" do
      cli = %{
        "codrift-cli-1.2.3-aarch64-apple-darwin.tar.gz" => "https://example.test/cli.tar.gz"
      }

      assert :error = Updater.desktop_asset(cli, "aarch64-apple-darwin")
    end
  end

  describe "app_manager/1" do
    # `:unknown`, not `:self`. Without CODRIFT_APP_PATH there is no bundle to
    # replace, and guessing one is how a self-update overwrites the wrong tree.
    test "is unknown when the shell named no app" do
      assert Updater.app_manager(nil) == :unknown
      assert Updater.app_manager("") == :unknown
    end

    test "is homebrew for a bundle inside a Caskroom" do
      assert Updater.app_manager("/opt/homebrew/Caskroom/codrift/0.2.7/Codrift.app") == :homebrew
    end
  end

  describe "brew_upgrade_command/0" do
    # The cask depends on the formula but `brew upgrade codrift` bumps the cask
    # alone, which is the mismatch Casks/codrift.rb's caveats warn about.
    test "always names the cask" do
      assert Updater.brew_upgrade_command() =~ ~r/^brew upgrade codrift\b/
    end

    test "matches the command the cask's caveats tell users to run" do
      cask = File.read!(Path.join(@repo_root, "Casks/codrift.rb"))
      assert cask =~ "brew upgrade codrift codrift-cli"
    end
  end

  describe "cli_asset_url/2" do
    test "points at the GitHub release download path for the v-prefixed tag" do
      assert Updater.cli_asset_url("0.1.0", "aarch64-apple-darwin") ==
               "https://github.com/filipecabaco/codrift/releases/download/v0.1.0/" <>
                 "codrift-cli-0.1.0-aarch64-apple-darwin.tar.gz"
    end
  end

  describe "release.yml checksum publishing" do
    test "release.yml publishes .sha256 assets that install.sh and the updater verify" do
      yml = File.read!(@release_yml)

      # Everything that ships is collected into dist/, every file there gets a
      # sibling checksum, and the whole directory is uploaded — so the
      # `<asset-url>.sha256` that verify_sha/download fetch always resolves.
      assert yml =~ ~S(shasum -a 256 "$f" > "$f.sha256")
      assert yml =~ "files: dist/*"

      assert File.read!(@install_sh) =~ "verify_sha"
    end
  end

  describe "release.yml version stamping" do
    test "stamps the release version into mix.exs, not just tauri.conf.json" do
      yml = File.read!(@release_yml)

      # current_version/0 reads the OTP app vsn, which comes from mix.exs. If the
      # release stops stamping it, every published build reports the placeholder
      # version, sees itself as older than the release it *is*, and reinstalls on
      # every update check.
      assert yml =~ "mix.exs"
      assert yml =~ "tauri.conf.json"
    end
  end

  describe "current_version/0" do
    test "returns the application version" do
      assert Updater.current_version() =~ ~r/^\d+\.\d+\.\d+$|^dev$/
    end
  end

  describe "install_dir/1" do
    test "uses RELEASE_ROOT, the tree the running binary was booted from" do
      assert Updater.install_dir("/opt/homebrew/Cellar/codrift-cli/0.0.5/libexec") ==
               "/opt/homebrew/Cellar/codrift-cli/0.0.5/libexec"
    end

    test "falls back to install.sh's location when not running from a release" do
      assert Updater.install_dir(nil) == Path.expand("~/.local/share/codrift")
      assert Updater.install_dir("") == Path.expand("~/.local/share/codrift")
    end

    test "resolves the home directory at runtime, not at compile time" do
      # `@install_dir Path.expand("~/...")` as a module attribute is evaluated
      # while compiling, so every published binary carried the *build machine's*
      # home: shipped `codrift update` died on
      # "could not make directory /Users/runner/.local/share/codrift".
      source = File.read!(Path.join(@repo_root, "lib/codrift/updater.ex"))

      refute source =~ ~r/@\w+\s+Path\.expand/,
             "Path.expand/1 in a module attribute bakes the build machine's " <>
               "home into the release; expand at runtime instead"

      refute Updater.install_dir(nil) =~ "/Users/runner/",
             "install dir resolved to the CI runner's home"
    end
  end

  describe "external_package_manager/1" do
    test "flags a Homebrew Cellar tree, which brew owns" do
      assert {:ok, command} =
               Updater.external_package_manager("/opt/homebrew/Cellar/codrift-cli/0.0.5/libexec")

      assert command =~ "brew upgrade"
      # The cask ships the app and the formula ships the CLI, and `brew upgrade
      # codrift` alone moves only the cask — which is how an "upgraded" install
      # keeps reporting the old CLI version.
      assert command =~ "codrift-cli"
    end

    test "leaves install.sh's own tree to self-update" do
      assert Updater.external_package_manager(Path.expand("~/.local/share/codrift")) == :error
    end
  end

  describe "install/1" do
    @tag :tmp_dir
    test "refuses to overwrite a Homebrew-managed tree", %{tmp_dir: tmp_dir} do
      cellar = Path.join([tmp_dir, "Cellar", "codrift-cli", "0.0.5", "libexec"])
      File.mkdir_p!(cellar)

      # Passes the directory in rather than mutating RELEASE_ROOT, so this stays
      # safe under async: true. The refusal comes before any download.
      assert {:error, reason} = Updater.install("0.0.9", cellar)
      assert reason =~ "Homebrew"
      assert reason =~ "brew upgrade"
    end
  end

  describe "install_tarball/2" do
    @tag :tmp_dir
    test "replaces the existing tree", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "codrift")
      File.mkdir_p!(Path.join(dir, "bin"))
      File.write!(Path.join([dir, "bin", "codrift"]), "old launcher")
      File.write!(Path.join(dir, "stale-file"), "from the previous version")

      assert :ok = Updater.install_tarball(release_tarball(tmp_dir, "new launcher"), dir)

      assert File.read!(Path.join([dir, "bin", "codrift"])) == "new launcher"
      # A swap, not an overlay: files the new release dropped must not survive.
      refute File.exists?(Path.join(dir, "stale-file"))
      refute File.exists?(dir <> ".new")
      refute File.exists?(dir <> ".old")
    end

    @tag :tmp_dir
    test "installs into a directory that does not exist yet", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "codrift")

      assert :ok = Updater.install_tarball(release_tarball(tmp_dir, "launcher"), dir)
      assert File.read!(Path.join([dir, "bin", "codrift"])) == "launcher"
    end

    @tag :tmp_dir
    test "leaves the working install intact when the archive is not a release",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "codrift")
      File.mkdir_p!(Path.join(dir, "bin"))
      File.write!(Path.join([dir, "bin", "codrift"]), "old launcher")

      tarball = Path.join(tmp_dir, "junk.tar.gz")
      write_tarball(tarball, [{~c"README", "not a release"}])

      assert {:error, reason} = Updater.install_tarball(tarball, dir)
      assert reason =~ "bin/codrift"

      # The whole point of staging: a bad download must not leave the user
      # without the `codrift` they were running.
      assert File.read!(Path.join([dir, "bin", "codrift"])) == "old launcher"
      refute File.exists?(dir <> ".new")
    end

    @tag :tmp_dir
    test "reports unreadable archives instead of raising", %{tmp_dir: tmp_dir} do
      assert {:error, reason} =
               Updater.install_tarball(
                 Path.join(tmp_dir, "missing.tar.gz"),
                 Path.join(tmp_dir, "codrift")
               )

      assert reason =~ "could not unpack"
    end
  end

  defp release_tarball(tmp_dir, launcher) do
    path = Path.join(tmp_dir, "release.tar.gz")
    write_tarball(path, [{~c"bin/codrift", launcher}])
    path
  end

  defp write_tarball(path, entries) do
    entries = Enum.map(entries, fn {name, content} -> {name, content} end)
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end
end
