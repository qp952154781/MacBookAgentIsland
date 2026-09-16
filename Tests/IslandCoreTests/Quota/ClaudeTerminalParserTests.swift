import Foundation
import Testing
@testable import IslandCore

private let recordedFixtures = ["trust-dialog", "repl-remote-control", "repl-no-chrome", "repl-final-flags"]
func recordedPTYFixture(_ name: String) throws -> Data {
    let root = try #require(Bundle.module.resourceURL)
    return try Data(contentsOf: root.appendingPathComponent("Fixtures/claude-pty/\(name).ansi"))
}

func chunks(_ data: Data, size: Int) -> [Data] {
    var seed: UInt64 = 0x4_7
    var offset = 0
    var result: [Data] = []
    while offset < data.count {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let count = min(size == 0 ? Int(seed % 97) + 1 : size, data.count - offset)
        result.append(data.subdata(in: offset..<(offset + count))); offset += count
    }
    return result
}

@Suite(.serialized)
struct ClaudeTerminalTests {
@Test(arguments: recordedFixtures)
func recordedTerminalClassificationAndWriteGate(name: String) async throws {
    let data = try recordedPTYFixture(name)
    let setup = name == "trust-dialog"
    var parser = ClaudeTerminalParser()
    parser.consume(data)
    #expect(parser.isReady == !setup)
    if setup {
        guard case .needsUserSetup = parser.terminalResult else {
            Issue.record("Recorded \(name) must contain a setup dialog"); return
        }
    } else { #expect(parser.terminalResult == nil) }

    for size in [data.count, 1, 7, 0] {
        let pieces = chunks(data, size: size)
        var gate = ClaudePTYWriteGate()
        for piece in pieces { gate.consume(piece) }
        #expect(gate.beginUsage() == !setup)
        #expect(gate.hasOpened == !setup)
        let pty = FakeClaudePTY(chunks: pieces)
        let future = Date().addingTimeInterval(28_800)
        let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast, future]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, directory: URL(fileURLWithPath: "/fixture"), timeout: 10)
        let result = await refresher.refresh()
        if setup {
            if case .needsUserSetup = result {} else { Issue.record("Expected setup for \(name)") }
            #expect(await pty.messages.isEmpty)
            #expect(await !pty.graceful)
        } else {
            #expect(result == .refreshed(future))
            #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
            #expect(await pty.graceful)
        }
        #expect(await pty.finished)
    }
}

@Test(arguments: recordedFixtures, [1, 7, 0])
func recordedTerminalChunksMatchWholeScreen(name: String, size: Int) throws {
    let data = try recordedPTYFixture(name)
    var whole = ClaudeTerminalParser(), split = ClaudeTerminalParser()
    whole.consume(data)
    for piece in chunks(data, size: size) { split.consume(piece) }
    #expect(split.text == whole.text)
    #expect(split.terminalResult == whole.terminalResult)
    #expect(split.isReady == whole.isReady)
    #expect(split.isComplete == whole.isComplete)
}

// Synthetic screen based on the controller's observed terminal wording in M4.8, not captured bytes.
// Production passes --no-chrome; this is defensive coverage of a one-time setup prompt.
@Test func syntheticChromeNoticeNeverOpensWriteGate() {
    let lines = ["Claude in Chrome extension detected",
                 "Claude will use your Chrome browser by default …",
                 "❯ No, keep browser tools off", "Yes, use my browser",
                 "Enter to confirm · Esc to keep browser tools off"]
    let screen = lines.map { line in
        var column = 1
        return line.split(separator: " ").map { word in
            defer { column += word.count + 1 }
            return "\u{1b}[\(column)G\(word)"
        }.joined()
    }.joined(separator: "\r\n")
    let data = Data(screen.utf8)
    for size in [data.count, 1, 7, 0] {
        var parser = ClaudeTerminalParser(), gate = ClaudePTYWriteGate()
        for piece in chunks(data, size: size) {
            parser.consume(piece)
            gate.consume(piece)
            #expect(!gate.isOpen)
            #expect(gate.beginUsage() == false)
            #expect(!gate.hasOpened)
        }
        #expect(!parser.isReady)
        if case .needsUserSetup = parser.terminalResult {} else { Issue.record("Expected Chrome setup") }
        if case .needsUserSetup = gate.result {} else { Issue.record("Expected latched Chrome setup") }
    }
}

@Test func terminalCursorMovementAndErasure() {
    var parser = ClaudeTerminalParser()
    #expect(parser.consume(Data("Quick\u{1b}[8Gsafety\u{1b}[15Gcheck:".utf8)) == "quick  safety check:")
    parser = ClaudeTerminalParser()
    #expect(parser.consume(Data("ab\u{1b}[3Cz\u{1b}[2DX".utf8)) == "ab  xz")
    #expect(parser.consume(Data("\rHi\u{1b}[K".utf8)) == "hi")
    #expect(parser.consume(Data("\u{1b}[3;4Hend\u{1b}[2Hmiddle".utf8)) == "hi\nmiddle\n   end")
    #expect(parser.consume(Data("\u{1b}[1;2H\u{1b}[1K".utf8)) == "  \nmiddle\n   end")
    #expect(parser.consume(Data("\u{1b}[2;3H\u{1b}[J".utf8)) == "  \nmi")
    #expect(parser.consume(Data("\u{1b}[2J\u{1b}[Hok".utf8)) == "ok\n")
    #expect(parser.consume(Data("\u{1b}[2;3Hx\u{1b}[1J".utf8)) == "\n   ")
    #expect(parser.consume(Data("\u{1b}[2K".utf8)) == "\n")
}

@Test func terminalIgnoresStylesOSCAndPrivateSequencesAcrossBytes() {
    let data = Data("\u{1b}[?25l\u{1b}[>4m\u{1b}]0;no, exit\u{7}\u{1b}]title\u{1b}\\\u{1b}(B\u{1b}[32m❯ 中文\u{1b}[0m".utf8)
    var parser = ClaudeTerminalParser()
    for byte in data { parser.consume(Data([byte])) }
    #expect(parser.text == "❯ 中文")
    #expect(parser.terminalResult == nil)
    #expect(parser.isComplete)
}

@Test func terminalMatchesBothSpacedAndCompactRulesAndLatchesAcrossClear() {
    for rule in ClaudeTerminalParser.setupRules {
        for spelling in [rule.uppercased(), rule.filter { !$0.isWhitespace }, rule.replacingOccurrences(of: " ", with: "\t\u{a0}")] {
            #expect(ClaudeTerminalParser.result(spelling) != nil)
        }
        var gate = ClaudePTYWriteGate()
        gate.consume(Data((rule + "\u{1b}[2J\u{1b}[H" + handwrittenClaudePrompt).utf8))
        #expect(!gate.isOpen)
        #expect(gate.beginUsage() == false)
        #expect(!gate.hasOpened)
        if case .needsUserSetup = gate.result {} else { Issue.record("Setup must remain latched") }
    }
}

@Test func terminalRequiresInputWithBothSeparatorsAndNoSetup() {
    let border = String(repeating: "─", count: 20)
    for prompt in ["❯", "❯ Try \"edit file\"", "❯\u{a0}Try\"edit<filepath>to...\""] {
        #expect(ClaudeTerminalParser.hasPrompt(border + "\n\n" + prompt + "\n\n" + border))
        #expect(!ClaudeTerminalParser.hasPrompt(prompt + "\n" + border))
        #expect(!ClaudeTerminalParser.hasPrompt(border + "\n" + prompt))
        #expect(!ClaudeTerminalParser.hasPrompt(String(repeating: "─", count: 19) + "\n" + prompt + "\n" + border))
        #expect(!ClaudeTerminalParser.hasPrompt(border + "\n" + prompt + "\n" + border + "\nNo, exit"))
    }
    #expect(!ClaudeTerminalParser.hasPrompt(border + "\n>\n" + border))
}

@Test func terminalWriteGateClosesOnRedrawOrIncompleteSequence() {
    var gate = ClaudePTYWriteGate()
    gate.consume(Data(handwrittenClaudePrompt.utf8))
    #expect(gate.isOpen)
    gate.consume(Data("\u{1b}[".utf8))
    #expect(gate.beginUsage() == false)
    gate.consume(Data("2J".utf8))
    #expect(gate.beginUsage() == false)
    gate.consume(Data(("\u{1b}[H" + handwrittenClaudePrompt).utf8))
    #expect(gate.beginUsage() == true)
    #expect(gate.beginUsage() == false)
    gate.consume(Data("\nUse my browser".utf8))
    #expect(!gate.isOpen)
    gate.consume(Data(("\u{1b}[2J\u{1b}[H" + handwrittenClaudePrompt).utf8))
    #expect(!gate.isOpen)
}

@Test func terminalMalformedUTF8AndHugeCursorDoNotCrashOrOpenGate() {
    var parser = ClaudeTerminalParser()
    parser.consume(Data([0xe2, 0x41, 0xff]))
    #expect(parser.text == "�a�")
    parser.consume(Data("\u{1b}[999999999999999999999999999G".utf8))
    #expect(parser.terminalResult != nil)
    #expect(!parser.isReady)
}

@Test func terminalMultilineSetupSurvivesEraseInTheSameChunk() {
    let data = Data(("Quick\nsafety\ncheck\u{1b}[2J\u{1b}[H" + handwrittenClaudePrompt).utf8)
    for size in [data.count, 1, 7, 0] {
        var gate = ClaudePTYWriteGate()
        for piece in chunks(data, size: size) { gate.consume(piece) }
        if case .needsUserSetup = gate.result {} else { Issue.record("Multiline setup must remain latched") }
        #expect(gate.beginUsage() == false)
        #expect(!gate.hasOpened)
    }
}

}
