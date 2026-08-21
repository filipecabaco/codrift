cask "codrift" do
  version "0.2.2"

  on_arm do
    sha256 "ec2fb7df2d1cfc5b700cac0a64233c8e13f6f9d152acf96b93996398e7fc9466"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_aarch64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end
  on_intel do
    sha256 "bd34bd9c97b184fc2a16755edbdeb0d34fbf4db59e9540b5c45dc29a6d482fcd"

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
