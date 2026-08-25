class CodriftCli < Formula
  desc "Headless CLI for Codrift: MCP setup, initiatives, sessions and memory"
  homepage "https://github.com/filipecabaco/codrift"
  version "0.2.6"

  # The cask ships Codrift.app; this ships the `codrift` command it documents.
  # Both are bumped together by the cask job in .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "4ac356f0930005812f2cfa0fb4a8e2ae0d05735ae5461c570796327ccd82b461"
    end
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "534f725922d581e8c7df7a477de0e35d60e4f72d23ef2192b44de882c249a020"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-linux-gnu.tar.gz"
      sha256 "b4fbe34409c86b51595640ef6300285bae9275d07fd46c4423b7527ac8829edd"
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
