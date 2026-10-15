import Foundation
import HarborCore
@testable import HarborControl
import Testing

@Suite("Key sequences")
struct KeySequenceTests {
    @Test(arguments: [
        ("enter", [0x0D]), ("ctrl+c", [0x03]), ("C-d", [0x04]), ("^z", [0x1A]), ("ctrl+[", [0x1B]),
        ("up", [0x1B, 0x5B, 0x41]), ("alt+b", [0x1B, 0x62]), ("f5", Array("\u{1B}[15~".utf8)), ("q", [0x71]),
    ] as [(String, [UInt8])])
    func encodes(key: String, expected: [UInt8]) throws {
        #expect(try KeySequence.bytes(for: key) == expected)
    }

    @Test func rejectsUnknownKeys() {
        #expect(throws: KeySequence.ParseError.self) { try KeySequence.bytes(for: "hyper+x") }
    }
}

@Suite("Control policy")
struct ControlPolicyTests {
    let assistant = ControlClient(kind: .assistant, name: "Claude")
    let browser = ControlClient(kind: .web, name: "203.0.113.7")

    @Test func assistantDefaultsAreConservative() {
        let settings = AppSettings()
        #expect(ControlPolicy.decide(.readScreen, client: assistant, settings: settings) == .allow)
        #expect(ControlPolicy.decide(.sendInput, client: assistant, settings: settings) == .ask)
        if case .deny = ControlPolicy.decide(.closeSession, client: assistant, settings: settings) {} else {
            Issue.record("closing tabs should be denied by default")
        }
    }

    @Test func disablingMCPDeniesEverything() {
        var settings = AppSettings()
        settings.ai.mcpEnabled = false
        for action in [ControlAction.readScreen, .sendInput, .openSession, .focusSession] {
            if case .deny = ControlPolicy.decide(action, client: assistant, settings: settings) {} else {
                Issue.record("\(action) should be denied")
            }
        }
    }

    @Test func browserRespectsReadOnlyMode() {
        var settings = AppSettings()
        settings.remote.enabled = true
        #expect(ControlPolicy.decide(.sendInput, client: browser, settings: settings) == .allow)
        settings.remote.allowInput = false
        if case .deny = ControlPolicy.decide(.sendInput, client: browser, settings: settings) {} else {
            Issue.record("read-only remote access must deny input")
        }
        #expect(ControlPolicy.decide(.readScreen, client: browser, settings: settings) == .allow)
    }
}
