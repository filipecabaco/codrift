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
end
