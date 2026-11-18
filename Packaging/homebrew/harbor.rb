# Homebrew cask for Harbor. Publish it in your own tap (github.com/Enuclea/homebrew-tap),
# then users install with:  brew install --cask Enuclea/tap/harbor
cask "harbor" do
  version "0.2.0"
  sha256 "2f311594879855eb7c0a259c83e4cd473eae40f77583b031ccfdca313250aaa9"

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
