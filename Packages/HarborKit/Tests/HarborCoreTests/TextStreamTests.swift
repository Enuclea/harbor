import Foundation
@testable import HarborCore
import Testing

@Suite("OSC scanner")
struct OSCScannerTests {
    @Test func findsBELTerminatedSequences() {
        var scanner = OSCScanner()
        let events = scanner.scan(Data("text\u{1b}]7;file://mac/Users/dan\u{07}more".utf8))
        #expect(events == [OSCEvent(code: 7, payload: "file://mac/Users/dan")])
    }

    @Test func findsSTTerminatedSequences() {
        var scanner = OSCScanner()
        let events = scanner.scan(Data("\u{1b}]133;D;2\u{1b}\\".utf8))
        #expect(events == [OSCEvent(code: 133, payload: "D;2")])
    }

    @Test func handlesSequencesSplitAcrossChunks() {
        var scanner = OSCScanner()
        #expect(scanner.scan(Data("abc\u{1b}]13".utf8)).isEmpty)
        #expect(scanner.scan(Data("3;A".utf8)).isEmpty)
        #expect(scanner.scan(Data("\u{07}".utf8)) == [OSCEvent(code: 133, payload: "A")])
    }

    @Test func ignoresCSISequences() {
        var scanner = OSCScanner()
        #expect(scanner.scan(Data("\u{1b}[31mred\u{1b}[0m".utf8)).isEmpty)
    }

    @Test func handlesCodeWithoutPayload() {
        var scanner = OSCScanner()
        #expect(scanner.scan(Data("\u{1b}]104\u{07}".utf8)) == [OSCEvent(code: 104, payload: "")])
    }
}

@Suite("ANSI stripper")
struct ANSIStripperTests {
    @Test func removesColoursAndTitles() {
        let raw = "\u{1b}]0;title\u{07}\u{1b}[1;32mok\u{1b}[0m\r\n"
        #expect(ANSIStripper.plainText(from: Data(raw.utf8)) == "ok\n")
    }

    @Test func appliesBackspaceToWholeCharacters() {
        #expect(ANSIStripper.plainText(from: Data("caf\u{e9}\u{08}e".utf8)) == "cafe")
    }

    @Test func keepsStateAcrossChunks() {
        var stripper = ANSIStripper()
        let first = stripper.strip(Data("a\u{1b}[3".utf8))
        let second = stripper.strip(Data("8;5;12mb".utf8))
        #expect(first + second + stripper.finish() == "ab")
    }

    @Test func appliesCarriageReturnOverwrites() {
        // curl-style progress collapses to the final state.
        #expect(ANSIStripper.plainText(from: Data(" 10%\r 55%\r100% done\n".utf8)) == "100% done\n")
    }

    @Test func removesZshPromptEOLMark() {
        let raw = "hi\r\n\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m" + String(repeating: " ", count: 39) + "\r \r"
        #expect(ANSIStripper.plainText(from: Data(raw.utf8)).trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
    }

    @Test func honoursEraseInLine() {
        #expect(ANSIStripper.plainText(from: Data("garbage\r\u{1b}[Kclean".utf8)) == "clean")
    }

    @Test func removesCharsetSelection() {
        #expect(ANSIStripper.plainText(from: Data("\u{1b}(Bplain".utf8)) == "plain")
    }
}

@Suite("UTF-8 stream decoder")
struct UTF8StreamDecoderTests {
    @Test func holdsBackIncompleteScalars() {
        var decoder = UTF8StreamDecoder()
        let bytes = Array("✓".utf8) // three bytes
        #expect(decoder.decode(Data(bytes.prefix(2))) == "")
        #expect(decoder.decode(Data(bytes.suffix(1))) == "✓")
    }

    @Test func passesCompleteTextThrough() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.decode(Data("héllo".utf8)) == "héllo")
    }
}
