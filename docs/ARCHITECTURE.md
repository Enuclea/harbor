# Harbor — Architecture

Harbor is a native macOS terminal: Terminal.app's feel, plus SSH host management, an
SFTP file flyout, an MCP server for AI assistants, and secure remote access from a browser.

> "Harbor" is a working name. It is defined once in `Config/Base.xcconfig`
> (`PRODUCT_NAME`, `HARBOR_BUNDLE_ID`) and in `HarborCore/Support/AppIdentity.swift`.

---

## 1. Stack decisions

| Concern | Choice | Why |
|---|---|---|
| Language / UI | Swift 6 (strict concurrency), AppKit for windows/terminal, SwiftUI for panels and the tab strip | AppKit gives the responder chain, key handling and window behaviour; SwiftUI is faster to build polished UI. Tabs are Harbor's own (not NSWindow tabbing) so each can show live status and the running command. |
| Terminal engine | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99, **Metal renderer** | Pure Swift, SPM, MIT. Ships a Metal renderer, OSC 133 semantic prompts, Kitty keyboard/graphics, sixel, thread-safe `feed`. Wrapped behind `TerminalSessionBinding` so a future swap (e.g. libghostty) touches one module. |
| PTY | Own C shim (`CHarborPTY`) + Swift `PTYProcess` | `fork` must run only async-signal-safe code in the child; doing that in C is the only fully correct option. We control `setsid`/`TIOCSCTTY`, fd hygiene, `IUTF8`. |
| SSH | System OpenSSH (`/usr/bin/ssh`) in a PTY | Honours the user's `~/.ssh/config`, agent, keychain, ProxyJump, FIDO keys, 2FA prompts — nothing to reimplement or audit. |
| File transfer | Own **SFTP v3 client** over `ssh -s <host> sftp`, reusing the tab's **ControlMaster** socket | No second login, no output-scraping of `ls`, binary-exact attributes, pipelined transfers. Tested against the real `/usr/libexec/sftp-server`. |
| MCP | Own JSON-RPC/MCP implementation in-app, exposed on a `0600` Unix socket; `harbor-mcp` stdio bridge for clients | MCP logic lives with the sessions it controls; the bridge is a dumb byte pipe, so it can never drift. |
| Web remote | [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) + WebSocket, bound to `127.0.0.1` only; xterm.js 6 front-end | NIO's HTTP parser is hardened for internet exposure. The server never listens on a public interface — a tunnel is the only way in. |
| Tunnels | `cloudflared` (quick or named tunnel + Cloudflare Access) or `tailscale serve` | Both give TLS and identity without opening ports. Tailscale is the most private; Cloudflare named tunnel + Access is the most "web". |
| Persistence | JSON files in `~/Library/Application Support/Harbor`, secrets in Keychain | Human-readable, diffable, dotfile-friendly. Forward-compatible decoding (missing keys fall back to defaults). |
| Logging | `os.Logger` (Console.app) + rotating JSONL file sink + live in-app viewer; separate audit trail; optional per-session asciicast/text recording | Covers dev, support and compliance needs with one facade. |
| Build | XcodeGen `project.yml` + local SPM package `HarborKit` | Declarative project, no merge-conflict-prone `.pbxproj`; all logic builds and tests with `swift test`. |
| Distribution | Developer ID + Hardened Runtime + notarized, stapled DMG; Sparkle 2 updates; Homebrew cask | A terminal cannot run sandboxed (it spawns arbitrary programs), so the Mac App Store is out. This is the same path Ghostty and iTerm2 take. |

## 2. Module map (no god modules)

```
                    ┌──────────── App target (main.swift → HarborAppController) ───────────┐
                    │                                                                      │
                 HarborUI  (AppKit windows/tabs, SwiftTerm binding, SwiftUI panels)        │
      ┌──────────┬──────┴─────┬────────────┬─────────────┬────────────┐                   │
 HarborRemote  HarborMCP  HarborSessions  HarborFiles  HarborDoctor  HarborShell          │
      │            │        │    │   │        │             │            │                │
      └──────┬─────┘        │    │   └── HarborSSH ─────────┘            │                │
        HarborControl ◄─────┘    │          │                            │                │
             │              HarborPTY ◄─────┘                            │                │
             │                   │  (CHarborPTY)                         │                │
             └───────────── HarborLogging ───────────────────────────────┘                │
                                 │                                                        │
                            HarborCore  (models, settings, paths, text-stream parsers)    │
                                                                                          │
 harbor-mcp (tool) ── HarborCore only: stdio ⇄ Unix socket ───────────────────────────────┘
```

| Module | Owns | Must not know about |
|---|---|---|
| `HarborCore` | IDs, `HostProfile`, `TerminalTheme`, `PromptConfig`, `AppSettings`, JSON stores, Keychain, `ProcessRunner`, OSC/ANSI stream parsers | Everything else |
| `HarborLogging` | Log facade, file sink + rotation, live feed, audit trail, session recorder | UI, sessions |
| `HarborPTY` | Spawning under a PTY, I/O, resize, foreground-process inspection, `ExpectSession` | Terminals, SSH |
| `HarborShell` | Shell-integration scripts (zsh/bash/fish), launch planning, prompt builder & installer | PTY, UI |
| `HarborSSH` | `ssh_config` parsing, command building, ControlMaster paths, key management | Sessions, UI |
| `HarborFiles` | SFTP v3 codec + client, local/remote file browsing, transfer queue | UI |
| `HarborControl` | The automation contract: DTOs, `TerminalControlling`, policy, key encoding | How sessions are implemented |
| `HarborSessions` | `TerminalSession`, `SessionManager`, launch planning, `SessionControlService` | AppKit / SwiftTerm |
| `HarborMCP` | JSON-RPC, MCP lifecycle, tool catalogue, Unix-socket transport | Sessions (talks only to `TerminalControlling`) |
| `HarborRemote` | HTTP/WebSocket server, auth, tunnel providers, web UI assets | Sessions (talks only to `TerminalControlling`) |
| `HarborDoctor` | Health checks, failure advice, support bundle | UI |
| `HarborUI` | Windows, native tabs, terminal view binding, Control Center, onboarding, flyout | — (composition root) |

Rules: dependencies point downward only; cross-module contracts are protocols
(`TerminalControlling`, `SessionPresenting`, `ScreenReading`, `ApprovalRequesting`,
`FileBrowsing`, `TunnelProvider`, `DiagnosticCheck`); files stay small and single-purpose.

## 3. Key flows

**Tab status.** `TerminalSession.activity` (HarborSessions) derives idle / busy / streaming /
exited from OSC 133 marks, the foreground process and output timing. zsh and fish report the
command line via `OSC 1337;HarborCommand=…`; commands an assistant types through MCP are recorded
directly, so line 2 of a tab is accurate even on hosts without shell integration.

**Keystroke → shell.** `TerminalView` (main thread) → `TerminalSession.send` → `PTYProcess`
write queue (non-blocking, back-pressured with a write source).

**Shell output → pixels.** PTY read source (dedicated queue, 64 KiB reads) → `OutputHub` fan-out,
on that queue, to: SwiftTerm `feedSender` (thread-safe, no main-thread hop), web clients,
recorder, replay ring buffer, OSC scanner. Only parsed *events* (cwd, title, command marks)
hop to the main actor, coalesced.

**SSH tab + file flyout.** The tab runs `ssh -o ControlMaster=auto -o ControlPath=~/.ssh/harbor/%C …`.
The flyout runs `ssh -o ControlPath=… -o BatchMode=yes -s host sftp`, riding the authenticated
master, and speaks SFTP v3. Drag out = Transferable file promise (download on drop);
drag in = upload to the current remote directory.

**AI assistant (MCP).** Claude Desktop / Claude Code launch `harbor-mcp`, which pipes stdio to
`~/Library/Application Support/Harbor/run/control.sock` (`0600`, peer-uid checked). If Harbor
isn't running, the bridge launches it. `MCPServer` maps tools → `TerminalControlling`,
which enforces the AI policy (read screen: allowed; typing: ask / ask once per tab / allow /
deny). Every AI action is written to the audit trail and the tab shows an "AI" indicator.

**Remote browser access.** Hummingbird on `127.0.0.1:<port>`. A tunnel publishes it.
Pairing uses a 256-bit token delivered as a URL *fragment* (never sent to the tunnel or logged),
exchanged for an `HttpOnly; SameSite=Strict` cookie. WebSockets check `Origin`, mirror the
native tab (replay buffer, then live), and obey a read-only switch.

**Prompt.** The Prompt builder (Control Center / onboarding) produces zsh, bash and fish
prompt files from one `PromptConfig`. Scope:
*Harbor sessions only* (injected via `ZDOTDIR` / `--rcfile` / `--init-command`, no dotfile edits),
*Everywhere* (managed, backed-up block in `~/.zshrc` / `~/.bashrc`), or *Keep my prompt*.

## 4. Should Harbor ship an onboard agent?

**Yes, as two layers, and not as an always-on watcher.**

1. **Doctor (deterministic, always present).** Typed health checks with one-click fixes:
   login shell, shell integration actually reporting in, `~/.ssh` permissions, agent and
   keychain state, ControlMaster socket-path length, MCP socket and client registration,
   tunnel binaries, App Translocation, log directory. It runs during onboarding and is
   **event-triggered**: when an SSH tab exits with status 255 within seconds, Harbor offers
   "Diagnose" and runs only the relevant checks (DNS, TCP reach, key permissions, host-key
   mismatch in the log tail). This finds most real install and connection problems with
   zero cost, zero latency and nothing leaving the machine.
2. **Assistant (optional, opt-in, next phase).** "Explain this" sends the Doctor report plus a
   *redacted* log tail to Claude (bring-your-own API key in Keychain) and returns an explanation
   with suggested fixes. Fixes are proposed as Doctor remedies or as a command placed in a
   tab — the user always presses the button. It reuses the MCP tool layer, so it gains no
   powers an external assistant doesn't have.

A background LLM "watching" the terminals adds cost and a privacy surface (terminal output holds
secrets) for little gain over event-triggered checks, so we don't build that.

## 5. Security model

* No App Sandbox (impossible for a terminal); Hardened Runtime, notarized.
* Control socket: `0700` directory, `0600` socket, `getpeereid` must equal our uid.
* AI policy defaults: read allowed, input **asks every time**, closing tabs denied.
* Remote server binds loopback only; token compared in constant time against a SHA-256 stored
  in Keychain; login rate-limited; strict CSP and no-store; WebSocket origin check;
  optional read-only mode. Recommended deployment: Tailscale, or a Cloudflare *named* tunnel
  behind a Cloudflare Access policy, so identity is enforced before traffic reaches the Mac.
* Session recording is off by default and records output only (never keystrokes).
* Secrets (remote token hash, tunnel tokens, future API keys) live in Keychain, never in JSON.

## 6. Terminal.app parity checklist

Title-bar tab strip with live status (drag to reorder or between windows, merge, move to new window) · profiles/themes · font & live zoom ·
cursor shape/blink · background opacity + blur · Option as Meta · bell (sound / visual / dock badge) ·
scrollback size · Find (⌘F/⌘G) · Clear scrollback (⌘K) · jump to previous/next prompt (⌘↑/⌘↓) ·
new tab in same directory · proxy icon for cwd · confirm close when a process is running ·
Secure Keyboard Entry · drag a file in to insert its escaped path · Export Text As… ·
`ssh://` URL handler · open folders with Harbor · OSC 8 hyperlinks · OSC 52 clipboard (policy-gated) ·
session restore.

## 7. Roadmap after v0.1

* Split panes (the session layer is already pane-agnostic).
* Cloudflare Access JWT verification in-app (defence in depth on top of the Access policy).
* Prompt sync to remote hosts over SFTP.
* Assistant layer (§4.2).
* Web management: edit hosts/settings from the browser (API exists; UI pending).
