# Harbor

A native macOS terminal that feels like Terminal.app, plus everything around it:
one-click SSH hosts, a drag-and-drop file flyout for every session, an MCP server so AI
assistants can work in your tabs, and secure access to all of it from a browser.

> "Harbor" is a working name. Change it in `Config/Base.xcconfig` and `AppIdentity.swift`.

## Features

**Tabs** — a two-line tab strip in the title bar. Line 1 is where (`user@host`, or the folder);
line 2 is what's running or last ran, with elapsed time. A live indicator shows idle, running,
streaming output, new output, bell, exited or failed; ✦ marks tabs and commands driven by an AI
assistant. Drag to reorder or between windows; ⌘1–9, ⌃Tab, Move to New Window, Merge All Windows.

**Terminal** — GPU (Metal) rendering via SwiftTerm, 14 themes, translucent and blurred backgrounds, font zoom, cursor styles,
Option-as-Meta, Find, Clear Scrollback, jump between prompts (⌘↑/⌘↓), new tabs in the same
folder, proxy icon, close confirmation for running jobs, Secure Keyboard Entry, drop files to
type their paths, Export Text, `ssh://` links, folders opened with Harbor, OSC 8 links,
policy-gated OSC 52 clipboard, session restore.

**Hosts and keys** — saved hosts with colours, tags, per-host themes, jump hosts and startup
commands. Import from `~/.ssh/config`, Quick Connect (⇧⌘K) with fuzzy search, Dock menu.
Generate Ed25519 keys, import by drag and drop, add to the agent with passphrases kept in the
Keychain, and install a key on a host in one click.

**Files** — ⇧⌘B opens a flyout on any tab. On SSH tabs it browses the server over SFTP,
reusing the tab's authenticated connection (no second login, no second 2FA prompt). Drag files
out to Finder (downloaded on drop) or in from Finder (uploaded); recursive folders, progress,
cancel, rename, delete, "cd here".

**Prompt** — design a prompt once (segments, colours, one or two lines) with a live preview and
apply it to zsh, bash and fish: only in Harbor (no dotfile edits) or everywhere.

**AI assistants (MCP)** — Claude Desktop, Claude Code, Cursor and Codex connect with one click.
Tools: `list_tabs`, `read_screen`, `run_command` (real output + exit code via shell
integration), `send_text`, `send_keys`, `wait_for_text`, `open_tab`, `connect_host`,
`focus_tab`, `close_tab`, `list_hosts`. Typing asks for approval by default; everything is
audited.

**Remote access** — a browser dashboard (xterm.js) for your tabs and hosts, served on loopback
only and published through Tailscale Serve or a Cloudflare tunnel. Token pairing by QR code or
link, HttpOnly cookies, CSRF/origin and DNS-rebinding protection, brute-force lockout,
read-only mode.

**Logging and diagnostics** — unified logging (Console.app), rotating JSON-lines files, a live
log viewer, an audit trail of assistant and browser actions, optional session recording
(text or asciicast), a Doctor with one-click fixes, failed-SSH diagnosis, and a redacted
support bundle.

## Install (users)

Download `Harbor-x.y.z.dmg`, drag Harbor to Applications, open it. Onboarding sets up your
prompt, imports SSH hosts, connects AI assistants and runs a health check. Or:

```bash
brew install --cask OWNER/tap/harbor
```

## Develop

Requirements: macOS 14+ to run, Xcode 26 and Homebrew to build.

```bash
make bootstrap
```

```bash
make run
```

```bash
make test
```

`make test` runs ~100 tests in the Swift package: live zsh sessions, a real
`/usr/libexec/sftp-server`, the `harbor-mcp` binary, and the HTTP/WebSocket server. Open
`Harbor.xcodeproj` (after `make project`) to work in Xcode; click **Trust & Enable** when Xcode
asks about SwiftTerm's build plugin.

Layout:

```
App/                    thin app target: main.swift, Sparkle, Info.plist, icon
Packages/HarborKit/     everything else, one module per concern (see docs/ARCHITECTURE.md)
Config/                 xcconfigs; put your Team ID in Config/Local.xcconfig
Scripts/                release, icon and vendoring scripts
Packaging/homebrew/     cask template
project.yml             XcodeGen spec (the .xcodeproj is generated)
```

## Release (Developer ID, notarized)

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and set `HARBOR_DEVELOPMENT_TEAM`.
2. Install your **Developer ID Application** certificate (Xcode ▸ Settings ▸ Accounts).
3. Store notarization credentials once:

   ```bash
   xcrun notarytool store-credentials harbor-notary --apple-id you@example.com --team-id ABCDE12345
   ```

4. `make release` produces a signed, notarized, stapled `build/release/Harbor-x.y.z.dmg` and
   prints its SHA-256 for the cask.

Auto-updates use Sparkle 2: generate keys with Sparkle's `generate_keys`, set
`HARBOR_APPCAST_URL` and `HARBOR_SPARKLE_PUBLIC_KEY` in `Local.xcconfig`, and publish an
appcast with `generate_appcast`. Until then "Check for Updates…" stays disabled.

## Using it with an assistant

Settings ▸ AI & MCP ▸ **Connect** next to your app. Manual config for any MCP client:

```json
{ "mcpServers": { "harbor": { "command": "/Applications/Harbor.app/Contents/MacOS/harbor-mcp" } } }
```

If Harbor isn't running, the bridge starts it.

## Security notes

* No App Sandbox (a terminal can't have one); Hardened Runtime and notarization instead.
* The control socket is `0600` in a `0700` directory and checks the peer's uid.
* Assistants: screen reading on, typing **asks every time**, closing tabs off — all configurable.
* Remote access is off by default. Prefer Tailscale, or a Cloudflare named tunnel behind a
  Cloudflare Access policy. Quick tunnels are public URLs protected only by the token.
* Passphrases go to `ssh-keygen`/`ssh-add` through a PTY, never argv. Secrets live in Keychain.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions, module boundaries and
the reasoning behind the diagnostics "agent".
