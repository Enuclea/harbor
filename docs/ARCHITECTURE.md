# Harbor — Architecture

Harbor is a native macOS terminal: Terminal.app's feel, plus SSH host management, live SSH port
redirects and SOCKS5 proxies, an SFTP file flyout with cross-host copy/paste, an onboard AI
command assistant and MCP server, a GitHub playbook library, and secure remote access from a
browser.

> "Harbor" is a working name. It is defined once in `Config/Base.xcconfig`
> (`PRODUCT_NAME`, `HARBOR_BUNDLE_ID`) and in `HarborCore/Support/AppIdentity.swift`.

---

## 1. Stack decisions

| Concern | Choice | Why |
|---|---|---|
| Language / UI | Swift 6 (strict concurrency), AppKit for windows/terminal, SwiftUI for panels and the tab strip | AppKit gives the responder chain, key handling and window behaviour; SwiftUI is faster to build polished UI. Tabs are Harbor's own (not NSWindow tabbing) so each can show live status, redirects, and the running command. |
| Terminal engine | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99, **Metal renderer** | Pure Swift, SPM, MIT. Ships a Metal renderer, OSC 133 semantic prompts, Kitty keyboard/graphics, sixel, thread-safe `feed`. Wrapped behind `TerminalSessionBinding` so a future swap (e.g. libghostty) touches one module. |
| PTY | Own C shim (`CHarborPTY`) + Swift `PTYProcess` | `fork` must run only async-signal-safe code in the child; doing that in C is the only fully correct option. We control `setsid`/`TIOCSCTTY`, fd hygiene, `IUTF8`. |
| SSH & port forwarding | System OpenSSH (`/usr/bin/ssh`) in a PTY + live `ControlMaster` (`-O forward` / `-O cancel`) | Honours `~/.ssh/config`, agent, keychain, ProxyJump, FIDO keys, 2FA prompts, and lets `-L`, `-R`, and `-D` SOCKS5 tunnels attach/detach on the fly without re-authenticating. |
| File transfer | Own **SFTP v3 client** over `ssh -s <host> sftp`, reusing the tab's **ControlMaster** socket | No second login, no output-scraping of `ls`, binary-exact attributes, pipelined transfers, and cross-host `FileClipboard` staging. Tested against the real `/usr/libexec/sftp-server`. |
| Onboard AI & MCP | `HarborAssist` (direct provider client + context budgeter) and `HarborMCP` (JSON-RPC over `0600` Unix socket + `harbor-mcp` stdio bridge) | Keeps MCP logic with the sessions it controls while letting users draft/explain commands inline (`⌘I`) with bring-your-own keys or local Ollama. |
| Web remote | [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) + WebSocket, bound to `127.0.0.1` only; xterm.js front-end | NIO's HTTP parser is hardened for internet exposure. The server never listens on a public interface — a tunnel is the only way in. |
| Tunnels | `cloudflared` (quick or named tunnel + Cloudflare Access) or `tailscale serve` | Both give TLS and identity without opening ports. Tailscale is the most private; Cloudflare named tunnel + Access is the most "web". |
| Persistence | JSON files in `~/Library/Application Support/Harbor`, secrets in Keychain | Human-readable, diffable, dotfile-friendly. Forward-compatible decoding (`LenientJSON` merges stored documents over defaults). |
| Logging | `os.Logger` (Console.app) + rotating JSONL file sink + live in-app viewer; separate audit trail; optional per-session asciicast/text recording | Covers dev, support and compliance needs with one facade. |
| Build | XcodeGen `project.yml` + local SPM package `HarborKit` | Declarative project, no merge-conflict-prone `.pbxproj`; all logic builds and tests with `swift test`. |
| Distribution | Developer ID + Hardened Runtime + notarized, stapled DMG; Sparkle 2 updates; Homebrew cask | A terminal cannot run sandboxed (it spawns arbitrary programs), so the Mac App Store is out. This is the same path Ghostty and iTerm2 take. |

## 2. Module map (no god modules)

```
                    ┌──────────── App target (main.swift → HarborAppController) ───────────────────┐
                    │                                                                              │
                 HarborUI  (AppKit windows/tabs, SwiftTerm binding, SwiftUI overlays & settings)   │
      ┌──────────┬──────┴─────┬────────────┬─────────────┬────────────┬─────────────┐              │
 HarborRemote  HarborMCP  HarborSessions  HarborFiles  HarborDoctor  HarborAssist  HarborHostSetup │
      │            │        │    │   │        │             │             │             │          │
      └──────┬─────┘        │    │   └── HarborSSH ─────────┴─────────────┼─────────────┘          │
        HarborControl ◄─────┘    │          │                             │                        │
             │              HarborPTY ◄─────┘                             │                        │
             │                   │  (CHarborPTY)                          │                        │
             └───────────── HarborLogging ◄───────────────────────────────┴── HarborShell          │
                                 │                                                │                │
                            HarborCore  (models, settings, paths, text-stream parsers) ◄───────────┘
                                                                                                   │
 harbor-mcp (tool) ── HarborCore only: stdio ⇄ Unix socket ────────────────────────────────────────┘
```

| Module | Owns | Must not know about |
|---|---|---|
| `HarborCore` | IDs, `HostProfile`, `PortForwardRule`, `SystemProfile`, `TerminalTheme`, `PromptConfig`, `AppSettings`, JSON stores, Keychain, `ProcessRunner`, OSC/ANSI stream parsers | Everything else |
| `HarborLogging` | Log facade, file sink + rotation, live feed, audit trail, session recorder | UI, sessions |
| `HarborPTY` | Spawning under a PTY, I/O, resize, foreground-process inspection, `ExpectSession` | Terminals, SSH |
| `HarborShell` | Shell-integration scripts (zsh/bash/fish), launch planning, prompt builder & installer | PTY, UI |
| `HarborSSH` | `ssh_config` parsing, command building (`-L`/`-R`/`-D` & `ssh -G` target resolution), `ConnectionSharing` live `ControlMaster` forwards, `HostProfileValidator`, key management | Sessions, UI |
| `HarborFiles` | SFTP v3 codec + client, local/remote file browsing, transfer queue | UI |
| `HarborControl` | The automation contract: DTOs, `TerminalControlling`, safe-command `ControlPolicy`, key encoding | How sessions are implemented |
| `HarborSessions` | `TerminalSession`, `InlineApprovalPrompt`, `SessionManager`, launch planning, `SessionRestoration`, `SessionControlService` | AppKit / SwiftTerm |
| `HarborMCP` | JSON-RPC, MCP lifecycle, tool catalogue, Unix-socket transport | Sessions (talks only to `TerminalControlling`) |
| `HarborAssist` | Onboard AI provider client (Anthropic, OpenAI, Gemini, Ollama), `ContextBudgeter` & secret redactor, `TokenLedger`, command drafting & failure explanation | AppKit, PTY |
| `HarborRemote` | HTTP/WebSocket server, auth, tunnel providers, web UI assets | Sessions (talks only to `TerminalControlling`) |
| `HarborDoctor` | Health checks, failure advice, support bundle | UI |
| `HarborHostSetup` | Remote shell-integration installer over SFTP + `GitHubScriptLibrary` (read-only git sync, playbook variable parser, `#dnr` public split exporter) | UI, sessions |
| `HarborUI` | Windows, native tabs, `PortForwardBar`, `CommandAssistBar`, `TerminalFindBar`, `FileBrowserPanel` & `FileClipboard`, Settings, onboarding | — (composition root) |

Rules: dependencies point downward only; cross-module contracts are protocols
(`TerminalControlling`, `SessionPresenting`, `ScreenReading`, `ApprovalRequesting`,
`FileBrowsing`, `TunnelProvider`, `DiagnosticCheck`); files stay small and single-purpose.

## 3. Key flows

**Tab status & custom host identity.** `TerminalSession.activity` (HarborSessions) derives idle /
busy / streaming / exited from OSC 133 marks, the foreground process, and output timing. zsh and
fish report the command line via `OSC 1337;HarborCommand=…`; commands an assistant types through
MCP are recorded directly. Hosts with `showsNameInPrompt` export a sanitized `LC_HARBOR_HOST` so
both the tab strip and the remote shell prompt display the friendly host name.

**Shell integration on SSH hosts (opt-in).** Host settings ▸ Install copies the zsh/bash/fish
scripts to `~/.harbor/shell` over SFTP and adds a marked block to the remote startup file that
loads them only in interactive shells with `LC_TERMINAL=Harbor`. The installer probes whether sshd
accepted the marker; if not (e.g. RHEL's default `AcceptEnv`), tabs to that host start the login
shell with `export LC_TERMINAL=Harbor; exec "$SHELL" -l`. Startup files are backed up once and the
block is removable from Harbor.

**Keystroke → shell.** `TerminalView` (main thread) → `TerminalSession.send` → `PTYProcess`
write queue (non-blocking, back-pressured with a write source). While an SSH session is still in
TCP/handshake setup (`!hasOutput`), `send` suppresses stray keystrokes except `⌃C` so local cooked
echo never leaks onto a blank terminal.

**Shell output → pixels.** PTY read source (dedicated queue, 64 KiB reads) → `OutputHub` fan-out,
on that queue, to: SwiftTerm `feedSender` (thread-safe, no main-thread hop), web clients,
recorder, replay ring buffer, OSC scanner. Only parsed *events* (cwd, title, command marks)
hop to the main actor, coalesced.

**SSH tab, live port redirects & file flyout.** Every SSH tab runs with
`ControlMaster=auto -o ControlPath=~/.ssh/harbor/%C` plus any `autoStart` `PortForwardRule`s
(`-L`, `-R`, `-D`).
* **Redirects & SOCKS5 (`⇧⌘L`)**: `PortForwardBar` and `HostEditorView` build `PortForwardRule`s
  supporting ports, `IP:port` / `host:port` bastion targets (e.g. `10.0.0.1:8291`), and bracketed
  IPv6 (`[fd00::1]:8291`). `ConnectionSharing` attaches or detaches rules on the live master via
  `ssh -O forward` / `ssh -O cancel`, updating tab badges, session banners, and host presets.
* **SFTP & cross-host clipboard (`⇧⌘B`)**: The flyout rides the same master socket (`ssh -T -s host
  sftp`) without stealing keyboard focus from the terminal. `⌘C` in a remote flyout downloads
  selected files/folders into `~/Library/Application Support/Harbor/Clipboard` and places file URLs
  on `NSPasteboard`, allowing direct `⌘V` into another SSH host's flyout or Finder.

**AI assistant (MCP + Onboard Assist).**
* **MCP (`harbor-mcp`)**: Pipes stdio to `~/Library/Application Support/Harbor/run/control.sock`
  (`0600`, peer-uid checked). Input requests render inline inside the target tab's `SessionOverlay`
  without stealing window focus (`Allow Once`, `Allow for Tab`, `Deny`), while single-line
  read-only commands matching configured prefixes can auto-run only when free of shell chaining or
  redirection (`;`, `|`, `&`, `>`, `<`, `$()`).
* **Onboard Assist (`⌘I`, `HarborAssist`)**: User- and event-triggered only (never an always-on
  background watcher). On first SSH output, Harbor optionally probes `uname` and common tooling on
  the shared connection (`SystemProfile`) so drafted commands match the host's OS, architecture,
  and package manager. `ContextBudgeter` redacts tokens/keys and caps prompt context before
  calling the configured provider.

**GitHub script library (`⇧⌘P`).** Clones or fast-forwards a user-configured repository into
`~/Library/Application Support/Harbor/github-scripts` with `remote.origin.pushurl` locked to
`DISABLED_READ_ONLY`. Playbooks declare `# @var:` and `# @secret:` metadata, warn on suspected
hardcoded secrets, and support exporting a clean public tree that strips `#dnr` lines and
`# @dnr` files.

**Remote browser access.** Hummingbird on `127.0.0.1:<port>`. Pairing uses a 256-bit token
delivered as a URL *fragment* (never sent to the tunnel or logged), exchanged for an
`HttpOnly; SameSite=Strict` cookie. WebSockets check `Origin`, mirror the native tab, and obey a
read-only switch.

## 4. Diagnostics & onboard AI model

1. **Doctor (deterministic, always present).** Typed health checks with one-click fixes:
   login shell, shell integration reporting, `~/.ssh` permissions, agent and keychain state,
   ControlMaster socket-path length, MCP socket and client registration, tunnel binaries, App
   Translocation, log directory. When an SSH tab exits with status 255 within seconds, Harbor
   offers "Diagnose" (`ssh -G` effective target resolution + DNS/TCP/key checks).
2. **Onboard Assist (opt-in, event- or user-triggered).** Invoked explicitly via `⌘I`, context
   menu "Explain Selection with AI", or non-zero exit chips. Suggestions are staged into the
   assist bar or typed only on confirmation, audited, and tracked in `TokenLedger`.

## 5. Security model

* No App Sandbox (impossible for a terminal); Hardened Runtime, notarized.
* Control socket: `0700` directory, `0600` socket, `getpeereid` must equal our uid.
* AI policy defaults: read allowed, input **asks every time**, closing tabs denied; safe prefix
  auto-approval rejects any shell chaining, redirection, or command substitution.
* Remote server binds loopback only; token compared in constant time against a SHA-256 stored
  in Keychain; global + per-client login rate-limiting; strict CSP and no-store; WebSocket origin
  check; optional read-only mode.
* Session recording is off by default and records output only (never keystrokes).
* Secrets (remote token hash, tunnel tokens, AI provider keys, GitHub credentials) live in
  Keychain, never in JSON.

## 6. Terminal.app parity checklist

Title-bar tab strip with live status (drag to reorder or between windows, merge, move to new
window, inline rename, middle-click close) · profiles/themes · configurable initial columns × rows ·
font & live zoom · cursor shape/blink · background opacity + blur · Option as Meta · bell (sound /
visual / dock badge) · scrollback size · Find bar (`⌘F`/`⌘G`, regex + case) · Clear scrollback
(`⌘K`) · jump to previous/next prompt (`⌘↑`/`⌘↓`) · new tab in same directory · proxy icon for cwd ·
confirm close when a process is running · Secure Keyboard Entry · drag a file in to insert its
escaped path · Export Text As… · `ssh://` & `harbor://` URL handlers · open folders with Harbor ·
OSC 8 hyperlinks · OSC 52 clipboard (policy-gated) · window & session restore.

## 7. Roadmap after v0.2

* Split panes (the session layer is already pane-agnostic).
* Cloudflare Access JWT verification in-app (defence in depth on top of the Access policy).
* Prompt sync to remote hosts over SFTP.
* Web management: edit hosts/settings from the browser (API exists; UI pending).
