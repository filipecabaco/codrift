class CodriftCli < Formula
  desc "Headless CLI for Codrift: MCP setup, initiatives, sessions and memory"
  homepage "https://github.com/filipecabaco/codrift"
  version "0.2.1"

  # The cask ships Codrift.app; this ships the `codrift` command it documents.
  # Both are bumped together by the cask job in .github/workflows/release.yml.
  on_macos do
    on_arm do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-aarch64-apple-darwin.tar.gz"
      sha256 "ec23c357b1faa4a8267975a9816959b0f066955f975997a4932f50abeb2991bb"
    end
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-apple-darwin.tar.gz"
      sha256 "7d4be197509d16ffec60c5765a57c2e55be808899021ab6df68201e57e5cd593"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/codrift-cli-#{version}-x86_64-linux-gnu.tar.gz"
      sha256 "a29ec2bbef8cd3356c474c1cd51cdf344d5f82e23e0a2b256e209d90a5847d60"
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
