import Foundation
import Testing
@testable import IslandCore

@Suite(.serialized)
struct ClaudeRefreshPhaseTests {
    @Test(arguments: [1, 7, 0], [false, true])
    func recordedUsageStreamAcceptsFreshExpiry(size: Int, initiallyValid: Bool) async throws {
        let startup = try recordedPTYFixture("repl-final-flags")
        let usage = try recordedPTYFixture("after-usage")
        var whole = ClaudePTYWriteGate(), split = ClaudePTYWriteGate()
        whole.consume(startup)
        #expect(whole.beginUsage() == true)
        for chunk in chunks(startup, size: size) { split.consume(chunk) }
        #expect(split.beginUsage() == true)
        whole.consume(usage)
        for chunk in chunks(usage, size: size) {
            split.consume(chunk)
            #expect(split.result == nil)
            #expect(split.beginUsage() == false)
        }
        #expect(split.result == whole.result)
        #expect(whole.result == nil)

        let clock = FakeQuotaClock()
        let fresh = clock.now().addingTimeInterval(28_800)
        let reader = FakeClaudeExpiry(initiallyValid ? [fresh] : [.distantPast, .distantPast, nil, fresh])
        let pty = FakeClaudePTY(chunks: chunks(startup, size: size), afterUsage: chunks(usage, size: size))
        let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: reader, makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 15, clock: clock)
        let task = Task { await refresher.refresh(force: true) }
        let polls = initiallyValid ? 1 : 3
        for poll in 1...polls {
            try await eventually { clock.pending == 3 && clock.sleeps.filter { $0 == 0.5 }.count == poll }
            #expect(await reader.reads == poll)
            clock.advance(0.5)
        }
        #expect(await task.value == (initiallyValid ? .alreadyFresh : .refreshed(fresh)))
        #expect(await reader.reads == polls + 1)
        #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
        #expect(await pty.finished)
        #expect(clock.pending == 0)
    }

    @Test(arguments: [1, 7, 0], ["oauth session expired and could not be refreshed", "refresh token expired", "invalid refresh token"])
    func usageStillDetectsLogin(size: Int, rule: String) async throws {
        // Handwritten login failure is appended after the supplied usage panel.
        let usage = try recordedPTYFixture("after-usage") + Data(("\r\n" + rule + "\u{1b}[2J").utf8)
        let pty = FakeClaudePTY(chunks: [Data(handwrittenClaudePrompt.utf8)], afterUsage: chunks(usage, size: size))
        let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 15)
        #expect(await refresher.refresh(force: true) == .needsLogin)
        #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
        #expect(await pty.finished)
    }

    @Test func expiryRequiresFiveMinutesAndDoesNotRequireIncrease() async throws {
        let clock = FakeQuotaClock()
        let now = clock.now()
        // A lower expiry is still valid; exactly five minutes remaining is accepted.
        let accepted = now.addingTimeInterval(302)
        let reader = FakeClaudeExpiry([now.addingTimeInterval(7200), nil, now, now.addingTimeInterval(300), accepted])
        let pty = FakeClaudePTY()
        let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: reader, makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, clock: clock)
        let task = Task { await refresher.refresh(force: true) }
        for poll in 1...4 {
            try await eventually { clock.pending == 3 && clock.sleeps.filter { $0 == 0.5 }.count == poll }
            #expect(await reader.reads == poll)
            #expect(await pty.messages == ["/usage\r"])
            clock.advance(0.499)
            #expect(await reader.reads == poll)
            clock.advance(0.001)
        }
        #expect(await task.value == .alreadyFresh)
        #expect(await reader.reads == 5)
        #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
    }

    @Test func usageHasIndependentTwentySecondDeadline() async throws {
        let clock = FakeQuotaClock(), pty = FakeClaudePTY()
        let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, clock: clock)
        let task = Task { await refresher.refresh(force: true) }
        try await eventually { clock.pending == 3 }
        #expect(clock.sleeps.sorted() == [0.5, 20, 60])
        clock.advance(19.999)
        try await eventually { clock.pending == 3 && clock.sleeps.count == 4 }
        #expect(await !pty.finished)
        clock.advance(0.001)
        #expect(await task.value == .failed("Claude 自动续期超时"))
        #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
        #expect(await pty.finished)
        #expect(clock.pending == 0)
    }

    @Test func cancellationAfterUsageClosesPanelAndExits() async throws {
        let pty = FakeClaudePTY()
        let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") })
        let task = Task { await refresher.refresh(force: true) }
        try await eventually { await pty.messages == ["/usage\r"] }
        task.cancel()
        if case .failed = await task.value {} else { Issue.record("Expected cancellation failure") }
        try await eventually { await pty.finished }
        #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
    }

    @Test func onlyUsageEscapeExitAreAllowedInOrder() {
        var input = ClaudePTYInputSequence()
        let commands = ["/usage\r", "\u{1b}", "/exit\r"]
        let forbidden = ["", "\r", "yes\r", "/login\r", "/usage\n", "/exit\n", "/usage\r\u{1b}", "hello\r"]
        for expected in commands {
            for command in commands + forbidden { #expect(input.allows(command) == (command == expected)) }
            input.didSend("hello\r")
            #expect(input.allows(expected))
            input.didSend(expected)
        }
        for command in commands + forbidden { #expect(!input.allows(command)) }
    }
}
