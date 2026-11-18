# Homebrew cask for Harbor. Publish it in your own tap (github.com/Enuclea/homebrew-tap),
# then users install with:  brew install --cask Enuclea/tap/harbor
cask "harbor" do
  version "0.2.0"
  sha256 "b9eb3f1428c5a37b7a1158cb6d51237bd5d6484cec8eef2d959d549391a47a87"

  url "https://github.com/Enuclea/harbor/releases/download/v#{version}/Harbor-#{version}.dmg"
  name "Harbor"
  desc "Native terminal with SSH hosts, port redirects, SFTP, onboard AI & MCP, and browser access"
  homepage "https://github.com/Enuclea/harbor"

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
