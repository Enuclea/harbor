# Harbor

A native macOS terminal that feels like Terminal.app, plus everything around it:
one-click SSH hosts, live port redirects and SOCKS5 proxies, a drag-and-drop SFTP file flyout
with cross-host copy/paste, an onboard AI command assistant and MCP server, a GitHub script
playbook library, and secure access to all of it from a browser.

> "Harbor" is a working name. Change it in `Config/Base.xcconfig` and `AppIdentity.swift`.

## Features

**Tabs & windows** — a two-line tab strip in the title bar. Line 1 is where (`user@host`, custom
host display name, or local folder); line 2 is what's running, last ran, or active SSH redirects,
with elapsed time. A live indicator shows idle, running, streaming output, new output, bell,
exited or failed; ✦ marks tabs and commands driven by an AI assistant, and `⇄` badges active port
redirects. Double-click a tab to rename inline, middle-click to close, drag to reorder or move
between windows, use the `+` menu to jump straight into saved remote hosts, and restore exact
window frames and tabs across launches (`⌘1–9`, `⌃Tab`, Move to New Window, Merge All Windows).

**Terminal** — GPU (Metal) rendering via SwiftTerm, 14 themes, translucent and blurred
backgrounds, font zoom, cursor styles, Option-as-Meta, inline Find bar (`⌘F` / `⌘G` with case and
regex toggles), Clear Scrollback (`⌘K`), jump between prompts (`⌘↑` / `⌘↓`), configurable
new-window columns × rows, new tabs in the same folder, proxy icon, close confirmation for running
jobs, Secure Keyboard Entry, drop files to type their paths (or upload to SSH tabs), Export Text,
`ssh://` and `harbor://` links, folders opened with Harbor, OSC 8 links, policy-gated OSC 52
clipboard, session restore.

**Hosts, keys & SSH redirects** — saved hosts with colours, tags, per-host themes, custom prompt
and tab names, jump hosts, and startup commands. Import from `~/.ssh/config`, Quick Connect
(`⇧⌘K`) with fuzzy search, Dock menu.
- **Port redirects & SOCKS5 proxies (`⇧⌘L`)**: toggle a 1-click dynamic SOCKS5 proxy (`-D`) or
  add local (`-L`) and reverse (`-R`) port redirects on the fly over the existing shared SSH
  `ControlMaster` connection—including internal `IP:port` and `[IPv6]:port` targets behind a
  bastion (e.g. `192.168.88.1:8291`). Pin redirects to a host or configure them in Host Settings
  to auto-start on connect, with clear indicators in the host list, tab strip, connecting banner,
  and session header.
- **SSH keys & remote shell integration**: generate Ed25519 keys, import by drag and drop, add to
  the agent with passphrases kept in Keychain, and install a key on a host in one click.
  Optionally install Harbor's shell integration on a host (one click, removable) so remote tabs
  report running commands, exit codes, and current directory just like local tabs.

**Files & cross-host clipboard** — `⇧⌘B` opens a non-blocking SFTP flyout beside any tab (reusing
the tab's authenticated SSH connection with no second login or 2FA prompt) while keeping keyboard
focus in the terminal. Drag files out to Finder or in from Finder, or press `⌘C` / `⌘V` in the
file list to copy and paste files and folders directly from one SSH server to another (or to/from
Finder); recursive folders, progress, cancel, rename, delete, "cd here".

**Onboard AI assist & MCP** — two complementary layers:
- **Inline Command Assist (`⌘I`)**: draft commands in natural language, explain selected output or
  non-zero exit codes via inline chips, and get context-aware next-step suggestions enriched with
  the target machine's `uname` / OS / package-manager profile. Supports Anthropic, OpenAI, Gemini,
  OpenAI-compatible endpoints, or local Ollama with a strict context budgeter, secret redactor,
  and token ledger.
- **MCP server (`harbor-mcp`)**: Claude Desktop, Claude Code, Cursor, and Codex connect in one
  click. Tools: `list_tabs`, `read_screen`, `run_command` (real output + exit code via shell
  integration), `send_text`, `send_keys`, `wait_for_text`, `open_tab`, `connect_host`,
  `focus_tab`, `close_tab`, `list_hosts`. Input requests appear as non-modal inline banners inside
  the target tab (`⌘↩` Allow Once, `⌥↩` Allow for Tab), with configurable safe read-only prefix
  auto-approval and full audit logging.

**GitHub script & playbook library (`⇧⌘P`)** — sync a repository of operational scripts as a
read-only local checkout (`pushurl` disabled), parse `# @var:` / `# @secret:` runtime parameters
into an interactive prompt before running in any local or SSH tab, flag accidental hardcoded
tokens, and export sanitized public splits honouring `#dnr` / `# @dnr` markers.

**Prompt** — design a prompt once (segments, colours, one or two lines) with a live preview and
apply it to zsh, bash and fish: only in Harbor (no dotfile edits) or everywhere.

**Remote access** — a browser dashboard (xterm.js) for your tabs and hosts, served on loopback
only and published through Tailscale Serve or a Cloudflare tunnel. Token pairing by QR code or
link, HttpOnly cookies, CSRF/origin and DNS-rebinding protection, brute-force lockout,
read-only mode.

**Logging and diagnostics** — unified logging (Console.app), rotating JSON-lines files, a live
log viewer, an audit trail of assistant and browser actions, optional session recording
(text or asciicast), a Doctor with one-click fixes, failed-SSH diagnosis, and a redacted
support bundle.

## Install (users)

Download `Harbor-x.y.z.dmg` from [Releases](https://github.com/Enuclea/harbor/releases), drag
Harbor to Applications, and open it. Onboarding sets up your prompt, imports SSH hosts, connects
AI assistants, and runs a health check. Or via Homebrew tap:

```bash
brew install --cask Enuclea/tap/harbor
```

## Develop

Requirements: macOS 14+ to run, Xcode 26 and Homebrew to build.

```bash
make bootstrap
make run
make test
```

`make test` runs ~155 tests across 13 test suites in the Swift package: live zsh sessions, a real
`/usr/libexec/sftp-server`, SSH port-forward & config parsers, the `harbor-mcp` binary, AI context
budgeting, GitHub `#dnr` playbook filtering, and the HTTP/WebSocket server. Open
`Harbor.xcodeproj` (after `make project`) to work in Xcode; click **Trust & Enable** when Xcode
asks about SwiftTerm's build plugin.

Layout:

```
App/                    thin app target: main.swift, Sparkle, Info.plist, icon
Packages/HarborKit/     everything else, one module per concern (see docs/ARCHITECTURE.md)
Config/                 xcconfigs; put your Team ID in Config/Local.xcconfig
Scripts/                release, icon and vendoring scripts
Packaging/homebrew/     cask definition
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
* Assistants: screen reading on, typing **asks every time** via inline per-tab approval banners
  (with optional single-command read-only prefix allowlist, rejecting pipes, redirects, and
  subshells), closing tabs off — all configurable.
* Remote access is off by default. Prefer Tailscale, or a Cloudflare named tunnel behind a
  Cloudflare Access policy. Quick tunnels are public URLs protected only by the token.
* Passphrases go to `ssh-keygen`/`ssh-add` through a PTY, never argv. API keys and SSH script
  credentials live in Keychain, never in JSON files.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions, module boundaries, and
key runtime flows.
