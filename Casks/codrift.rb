cask "codrift" do
  version "0.0.3"

  on_arm do
    sha256 "1fd4bdde0506322a15c0c682e0c31f4f124ba5226f345693ef355fceb38bbbcb"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_aarch64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end
  on_intel do
    sha256 "da27b8fff3a170069e63d34f2c1ce1c2d68bd083dee3845702300df25446dc10"

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
  EOS
end
