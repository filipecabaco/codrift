class CodriftCli < Formula
  desc "Headless CLI for Codrift: MCP setup, initiatives, sessions and memory"
  homepage "https://github.com/filipecabaco/codrift"
  version "0.2.0"

  # The cask ships Codrift.app; this ships the `codrift` command it documents.
  # Both are bumped together by the cask job in .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "ae5d0b329982a59a3335998017b369633a7c14f9d37215b63b173394525e9f59"
    end
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "8e447c21009d04745670770a7ec30ecc613b12627458303ad5f6716d682dd181"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-linux-gnu.tar.gz"
      sha256 "13aeee20a9aff2f53590e86a3bc23b7fe58d4cab86ae9fe32ef9cafa3f0386de"
    end
  end

  def install
    # A mix release tarball has bin/, lib/, erts-* and releases/ at its root with
    # no wrapping directory, and bin/codrift resolves RELEASE_ROOT from its own
    # location — so the tree has to stay intact. libexec keeps it whole and the
    # symlink (which the boot script readlinks through) is what lands on PATH.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/codrift"
  end

  test do
    # Exercises the whole path that matters here: the symlink resolves, the boot
    # script derives RELEASE_ROOT back to libexec, and the bundled ERTS starts.
    assert_match version.to_s, shell_output("#{bin}/codrift version")
  end
end
