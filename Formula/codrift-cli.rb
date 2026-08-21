class CodriftCli < Formula
  desc "Headless CLI for Codrift: MCP setup, initiatives, sessions and memory"
  homepage "https://github.com/filipecabaco/codrift"
  version "0.1.1"

  # The cask ships Codrift.app; this ships the `codrift` command it documents.
  # Both are bumped together by the cask job in .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "438902fa371bdafa6331c69e306c0205fec838eb021ad73a930ad315d01f5fb9"
    end
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "be9b249327beb449eb23150f753474f4e1d0074d74732590594d6f10c1e68b67"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-linux-gnu.tar.gz"
      sha256 "fd93848d9fa04e62fa9ee1045c8cb8a41c1845dff2dd0654e1a9b9797338584b"
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
