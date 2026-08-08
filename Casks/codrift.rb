cask "codrift" do
  version "0.0.1"

  on_arm do
    sha256 "983d11e0282973bdc116d0a2b6bb1d69b9994701a0f5b88e68cde6c3a9ff96e5"

    url "https://github.com/filipecabaco/codrift/releases/download/v#{version}/Codrift_#{version}_aarch64.dmg",
        verified: "github.com/filipecabaco/codrift/"
  end
  on_intel do
    sha256 "71bf105ed39dc29dabc1487607d2f2a1953d3b9404a14c6df67e8b07b87db305"

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
end
