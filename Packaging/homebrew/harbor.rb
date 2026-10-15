# Homebrew cask for Harbor. Publish it in your own tap (github.com/<you>/homebrew-tap),
# then users install with:  brew install --cask <you>/tap/harbor
cask "harbor" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/OWNER/harbor/releases/download/v#{version}/Harbor-#{version}.dmg"
  name "Harbor"
  desc "Native terminal with SSH hosts, file transfer, AI assistant (MCP) and browser access"
  homepage "https://github.com/OWNER/harbor"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Harbor.app"
  binary "#{appdir}/Harbor.app/Contents/MacOS/harbor-mcp"

  zap trash: [
    "~/Library/Application Support/Harbor",
    "~/Library/Logs/Harbor",
    "~/Library/Preferences/dev.harbor.Harbor.plist",
    "~/Library/Saved Application State/dev.harbor.Harbor.savedState",
    "~/.ssh/harbor",
  ]
end
