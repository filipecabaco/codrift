cask "codrift" do
  version "0.2.6"

  on_arm do
    sha256 "3c02867049c59ed6b7933bf3222941d939224d7abd58b5a2024bb2c70ff14bf6"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_aarch64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end
  on_intel do
    sha256 "c63fa1f3a3cc0e9bb2ed814206283edefc6df45ab6eb3f2b94c1510493a07be5"

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

  depends_on macos: :ventura
  # The DMG carries only the GUI — Contents/MacOS/codrift is the Tauri shell and
  # Contents/MacOS/desktop the Burrito sidecar, neither of which is the headless
  # CLI. So `binary` has nothing to point at, and without this the documented
  # `codrift mcp install` was a command that brew never installed.
  depends_on formula: "filipecabaco/codrift/codrift-cli"

  app "Codrift.app"

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

    Upgrading: the `codrift` command ships in the codrift-cli formula, and
    `brew upgrade codrift` bumps only the cask — brew does not upgrade a cask's
    formula dependencies. Upgrade both, or the app moves while the CLI keeps
    reporting the old version:

      brew upgrade codrift codrift-cli
  EOS
end
