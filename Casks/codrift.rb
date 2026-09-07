cask "codrift" do
  version "0.3.1"

  on_arm do
    sha256 "dadac4c5d45666bb5c6e290d15c78575ba1d84f546765b91fce3ad9520577a12"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_aarch64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end
  on_intel do
    sha256 "bcae554fe66be1d625b8377cd55613324bd1444301d653e8df5a01345778db8f"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_x64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end

  name "Codrift"
  desc "Drive multiple AI coding agents across your projects from one desktop app"
  homepage "https://github.com/filipecabaco/codrift"

  livecheck do
    url :url
    strategy :github_latest
  end

  # A leftover install of the old formula owns a `codrift` symlink in the same
  # Homebrew bin the stanza below writes to, so the install would fail on the
  # collision. Say which one to remove rather than let brew report a bare
  # "Binary already exists".
  conflicts_with formula: "filipecabaco/codrift/codrift-cli"
  depends_on macos: :ventura

  app "Codrift.app"
  # Contents/MacOS/desktop is the Burrito-wrapped sidecar: a complete release of
  # the same Elixir application the headless CLI is built from, which runs
  # `Codrift.CLI.Main` when it is handed argv (see `Codrift.start/2`). Pointing
  # at it is what makes this cask a single package. It used to `depends_on` a
  # `codrift-cli` formula, and brew then downloaded the same ~15 MB release
  # twice — once inside the DMG and once as a tarball — and, since brew does not
  # upgrade a cask's formula dependencies, let the two drift to different
  # versions.
  binary "#{appdir}/Codrift.app/Contents/MacOS/desktop", target: "codrift"

  # Codrift ships unsigned (no Apple Developer ID yet). Homebrew quarantines
  # downloaded artifacts, and Gatekeeper then refuses to open an unsigned,
  # un-notarized app ("Codrift is damaged and can't be opened"). Strip the
  # quarantine attribute on install so the app launches. Remove this block once
  # the DMG is signed + notarized in CI.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Codrift.app"],
                   sudo: false
  end

  uninstall quit: "app.codrift.desktop"

  # sh.codrift.app was the identifier up to 0.0.1; keep zapping its leftovers.
  zap trash: [
    "~/.codrift",
    "~/Library/Application Support/app.codrift.desktop",
    "~/Library/Application Support/sh.codrift.app",
    "~/Library/Caches/app.codrift.desktop",
    "~/Library/Caches/sh.codrift.app",
    "~/Library/Preferences/app.codrift.desktop.plist",
    "~/Library/Preferences/sh.codrift.app.plist",
    "~/Library/Saved Application State/app.codrift.desktop.savedState",
    "~/Library/Saved Application State/sh.codrift.app.savedState",
    "~/Library/WebKit/app.codrift.desktop",
    "~/Library/WebKit/sh.codrift.app",
  ]

  caveats <<~EOS
    Finish setup — from a terminal, or from Setup in Codrift's command palette (^P):

      codrift mcp install                   # register the MCP server with your AI CLIs
      npx skills add filipecabaco/codrift   # teach your agents how to drive Codrift

    The skills cover the shared memory store, initiatives, orchestration and
    the GitHub/Linear/GitLab integrations. Add -g to install them globally.

    The `codrift` command is a symlink into Codrift.app, so one upgrade moves
    both:

      brew upgrade codrift

    If you installed the old codrift-cli formula, remove it — it shadows this
    command on PATH and keeps reporting its own version:

      brew uninstall codrift-cli
  EOS
end
