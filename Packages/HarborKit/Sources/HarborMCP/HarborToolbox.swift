import Foundation
import HarborControl
import HarborCore

/// The tools Harbor exposes to assistants. Each is a thin adapter over `TerminalControlling`,
/// which owns policy, approvals and auditing.
public struct HarborToolbox: Sendable {
    public let tools: [MCPTool]

    public init(control: any TerminalControlling) {
        tools = Self.makeTools(control)
    }

    public func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    private static let read = MCPToolAnnotations(readOnly: true, destructive: false, idempotent: true)
    private static let navigate = MCPToolAnnotations(readOnly: false, destructive: false, idempotent: true)
    private static let write = MCPToolAnnotations(readOnly: false, destructive: true, idempotent: false)

    // swiftlint:disable:next function_body_length
    private static func makeTools(_ control: any TerminalControlling) -> [MCPTool] {
        [
            MCPTool(
                name: "list_tabs", title: "List tabs",
                description: "List every open terminal tab with its index, title, kind (local/ssh), host, working directory, foreground process and whether it is at a shell prompt.",
                inputSchema: Schema.object([:]), annotations: read
            ) { _, _ in .json(await control.listSessions()) },

            MCPTool(
                name: "get_tab", title: "Describe a tab",
                description: "Get details for one tab, including whether shell integration is active (needed for reliable run_command results).",
                inputSchema: Schema.object(["tab": Schema.tab]), annotations: read
            ) { args, _ in .json(try await control.describeSession(args.tab)) },

            MCPTool(
                name: "read_screen", title: "Read screen",
                description: "Return the text currently visible in a tab, optionally with lines of scrollback above it. Use this to see the state of interactive programs (editors, pagers, prompts) or long-running commands.",
                inputSchema: Schema.object([
                    "tab": Schema.tab,
                    "scrollback_lines": Schema.integer("Lines of history above the visible screen to include (default 0).", minimum: 0, maximum: 5_000),
                ]), annotations: read
            ) { args, client in
                let screen = try await control.readScreen(args.tab, scrollbackLines: args.int("scrollback_lines") ?? 0, client: client)
                var header = "Tab \(screen.sessionID.prefix(8)) — \(screen.columns)×\(screen.rows)"
                if let row = screen.cursorRow, let column = screen.cursorColumn { header += ", cursor at row \(row + 1) col \(column + 1)" }
                return .text(header + "\n" + String(repeating: "─", count: 40) + "\n" + screen.text)
            },

            MCPTool(
                name: "run_command", title: "Run a shell command",
                description: "Type a single-line command into a tab at its shell prompt, press Return, wait for it to finish and return its output and exit code. Requires the tab to be at a prompt. The user may be asked to approve. For interactive programs use send_text/send_keys and read_screen instead.",
                inputSchema: Schema.object([
                    "tab": Schema.tab,
                    "command": Schema.string("The command line to run, e.g. “git status”."),
                    "timeout_seconds": Schema.integer("How long to wait for completion (default 30, max 600).", minimum: 1, maximum: 600),
                ], required: ["command"]), annotations: write
            ) { args, client in
                let timeout = Duration.seconds(min(600, max(1, args.int("timeout_seconds") ?? 30)))
                let outcome = try await control.runCommand(args.tab, command: try args.requiredString("command"), timeout: timeout, client: client)
                var text = outcome.output.isEmpty ? "(no output)" : outcome.output
                if outcome.completed {
                    text += "\n\n[exit code: \(outcome.exitCode.map(String.init) ?? "unknown — shell integration inactive")]"
                } else {
                    text += "\n\n[still running after the timeout — use read_screen to check on it, or send_keys ctrl+c to stop it]"
                }
                return MCPToolResult(text: text, isError: outcome.completed && (outcome.exitCode ?? 0) != 0)
            },

            MCPTool(
                name: "send_text", title: "Type text",
                description: "Type text into a tab exactly as given. Set press_enter to submit it. Useful for answering prompts or working inside interactive programs. The user may be asked to approve.",
                inputSchema: Schema.object([
                    "tab": Schema.tab,
                    "text": Schema.string("The text to type."),
                    "press_enter": Schema.boolean("Press Return after typing (default false)."),
                ], required: ["text"]), annotations: write
            ) { args, client in
                let text = try args.requiredString("text") + (args.bool("press_enter") == true ? "\r" : "")
                try await control.sendInput(args.tab, text: text, client: client)
                return .text("Typed \(text.count) characters.")
            },

            MCPTool(
                name: "send_keys", title: "Press keys",
                description: "Press special keys in a tab, in order. Names: enter, tab, escape, backspace, delete, up, down, left, right, home, end, pageup, pagedown, space, f1–f12, ctrl+<key> (e.g. ctrl+c), alt+<key>.",
                inputSchema: Schema.object([
                    "tab": Schema.tab,
                    "keys": Schema.stringArray("Key names, e.g. [\"ctrl+c\"] or [\"escape\", \":\", \"w\", \"q\", \"enter\"]."),
                ], required: ["keys"]), annotations: write
            ) { args, client in
                guard let keys = args.strings("keys"), !keys.isEmpty else {
                    throw ControlError.invalidArgument("Provide at least one key name in “keys”.")
                }
                let bytes = try KeySequence.bytes(for: keys)
                try await control.sendInput(args.tab, text: String(decoding: bytes, as: UTF8.self), client: client)
                return .text("Pressed \(keys.joined(separator: ", ")).")
            },

            MCPTool(
                name: "wait_for_text", title: "Wait for text",
                description: "Wait until text matching a regular expression appears on a tab's screen (e.g. a build finishing or a prompt appearing). Returns the screen when it matches.",
                inputSchema: Schema.object([
                    "tab": Schema.tab,
                    "pattern": Schema.string("Regular expression to wait for."),
                    "timeout_seconds": Schema.integer("Maximum wait (default 30, max 600).", minimum: 1, maximum: 600),
                ], required: ["pattern"]), annotations: read
            ) { args, client in
                let pattern = try args.requiredString("pattern")
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    throw ControlError.invalidArgument("“\(pattern)” isn't a valid regular expression.")
                }
                let deadline = ContinuousClock.now + .seconds(min(600, max(1, args.int("timeout_seconds") ?? 30)))
                while true {
                    let screen = try await control.readScreen(args.tab, scrollbackLines: 0, client: client)
                    let text = screen.text
                    if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                        return .text("Matched “\(pattern)”.\n" + text)
                    }
                    guard ContinuousClock.now < deadline else {
                        return .error("Timed out waiting for “\(pattern)”. Current screen:\n" + text)
                    }
                    try await Task.sleep(for: .milliseconds(400))
                }
            },

            MCPTool(
                name: "open_tab", title: "Open a local tab",
                description: "Open a new local shell tab, optionally in a directory. Returns the new tab.",
                inputSchema: Schema.object(["directory": Schema.string("Absolute path to start in (default: home).")]),
                annotations: navigate
            ) { args, client in
                .json(try await control.openSession(.localShell(workingDirectory: args.string("directory")), client: client))
            },

            MCPTool(
                name: "connect_host", title: "Connect to a host",
                description: "Open an SSH tab to a saved host (by name or id from list_hosts) or to a destination like user@example.com:2222. Authentication happens in the tab; check it with read_screen.",
                inputSchema: Schema.object([
                    "host": Schema.string("Saved host name or id."),
                    "destination": Schema.string("Ad-hoc destination, e.g. deploy@10.0.0.5:2222."),
                ]), annotations: navigate
            ) { args, client in
                if let host = args.string("host") {
                    return .json(try await control.openSession(.savedHost(host), client: client))
                }
                guard let destination = args.string("destination") else {
                    throw ControlError.invalidArgument("Provide either “host” or “destination”.")
                }
                return .json(try await control.openSession(.destination(destination), client: client))
            },

            MCPTool(
                name: "focus_tab", title: "Switch to tab",
                description: "Bring a tab to the front so the user sees it.",
                inputSchema: Schema.object(["tab": Schema.tab], required: ["tab"]), annotations: navigate
            ) { args, client in .json(try await control.focusSession(args.tab, client: client)) },

            MCPTool(
                name: "close_tab", title: "Close tab",
                description: "Close a tab, ending its process. Disabled unless the user allows it in settings.",
                inputSchema: Schema.object(["tab": Schema.tab], required: ["tab"]), annotations: write
            ) { args, client in
                try await control.closeSession(args.tab, client: client)
                return .text("Closed.")
            },

            MCPTool(
                name: "list_hosts", title: "List saved hosts",
                description: "List the user's saved SSH hosts (name, destination, tags). Use connect_host to open one.",
                inputSchema: Schema.object([:]), annotations: read
            ) { _, _ in .json(await control.listHosts()) },
        ]
    }
}
