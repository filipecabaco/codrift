class CodriftCli < Formula
  desc "Headless CLI for Codrift: MCP setup, initiatives, sessions and memory"
  homepage "https://github.com/filipecabaco/codrift"
  version "0.0.4"

  # The cask ships Codrift.app; this ships the `codrift` command it documents.
  # Both are bumped together by the cask job in .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "027cb3840e54c2e03482b04f5512cd22bd437aa2d03ee75005c89b543c423c8b"
    end
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "7e6a370e3a2464cf7a7092498dd544ed7089c3f40884ba966c97cfd97bf8a686"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-linux-gnu.tar.gz"
      sha256 "8cc6b5f3426c1a2c21c44638494aec632337f4d9d567202ea236fcaa88c2e16a"
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
