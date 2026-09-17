import Foundation
import Testing
@testable import IslandCore

let handwrittenClaudePrompt = String(repeating: "─", count: 24) + "\n❯ \n" + String(repeating: "─", count: 24)

actor FakeClaudePTY: ClaudePTY {
    let chunks: [Data]
    let sendFailure: Bool
    private var input = ClaudePTYInputSequence()
    private let afterUsage: [Data]
    var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private(set) var messages: [String] = []
    private(set) var starts = 0
    private(set) var finished = false
    private(set) var graceful = false
    init(_ text: String = handwrittenClaudePrompt, sendFailure: Bool = false) {
        // Splitting every byte exercises ANSI and multibyte UTF-8 boundaries.
        chunks = Array(text.utf8).map { Data([$0]) }; self.sendFailure = sendFailure; afterUsage = []
    }
    init(chunks: [Data], afterUsage: [Data] = []) {
        self.chunks = chunks; self.afterUsage = afterUsage; self.sendFailure = false
    }
    func start(executable: URL, directory: URL) -> AsyncThrowingStream<Data, any Error> {
        starts += 1
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation = pair.continuation
        for chunk in chunks { pair.continuation.yield(chunk) }
        return pair.stream
    }
    func send(_ text: String) throws {
        guard !finished, input.allows(text) else { throw QuotaError.transient("fixture input phase") }
        messages.append(text)
        if sendFailure { throw QuotaError.transient("fixture") }
        input.didSend(text)
        if text == "/usage\r" {
            for chunk in afterUsage { continuation?.yield(chunk) }
        }
    }
    func emit(_ text: String) { continuation?.yield(Data(text.utf8)) }
    func finish(graceful: Bool) {
        guard !finished else { return }
        self.graceful = graceful && input.usageSent
        if self.graceful {
            try? send("\u{1b}")
            try? send("/exit\r")
        }
        finished = true
        continuation?.finish(); continuation = nil
    }
}
actor FakeClaudeExpiry: ClaudeExpiryReading {
    private var values: [Date?]
    private(set) var reads = 0
    init(_ values: [Date?]) { self.values = values }
    func expiry() -> Date? {
        reads += 1
        return values.count > 1 ? values.removeFirst() : values.first ?? nil
    }
}
actor FakeClaudeRefresher: ClaudeRefreshing {
    private(set) var calls: [Bool] = []
    var results: [ClaudeRefreshResult]
    init(_ results: [ClaudeRefreshResult] = [.failed("fixture")]) { self.results = results }
    func refresh(force: Bool) -> ClaudeRefreshResult {
        calls.append(force)
        return results.count > 1 ? results.removeFirst() : results.first ?? .failed("fixture")
    }
}

@Test func refreshAbandonsEverySetupRuleWithoutInput() async throws {
    for rule in ClaudeTerminalParser.setupRules {
        let pty = FakeClaudePTY("\u{1b}[32m" + rule + "\u{1b}[0m\n❯ ")
        let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, directory: URL(fileURLWithPath: "/fixture"), timeout: 6)
        if case .needsUserSetup = await refresher.refresh() {} else { Issue.record("Setup must abort: \(rule)") }
        try await eventually { await pty.finished }
        #expect(await pty.messages.isEmpty)
        #expect(await !pty.graceful)
    }
}

@Test func refreshNormalPromptRenewsAndCleansUp() async {
    let future = Date().addingTimeInterval(28_800)
    let pty = FakeClaudePTY("\u{1b}]0;Claude\u{7}\u{1b}[32m" + handwrittenClaudePrompt + "\u{1b}[0m")
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([Date(timeIntervalSince1970: 0), future]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 8)
    #expect(await refresher.refresh() == .refreshed(future))
    #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
    #expect(await pty.finished)
    #expect(await pty.graceful)
}

@Test func refreshTimeoutCancellationWriteFailureAndLoginCleanUp() async throws {
    for mode in ["timeout", "cancel", "write", "login"] {
        let pty = FakeClaudePTY(mode == "write" ? handwrittenClaudePrompt : mode == "login" ? "OAuth session expired and could not be refreshed" : "", sendFailure: mode == "write")
        let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
            locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: mode == "timeout" ? 5.05 : 6)
        let task = Task { await refresher.refresh() }
        if mode == "cancel" { try await eventually { await pty.starts == 1 }; task.cancel() }
        let result = await task.value
        if mode == "login" { #expect(result == .needsLogin) }
        else if case .failed = result {} else { Issue.record("Expected failure") }
        // Watchdog cancellation returns before the detached operation finishes cleanup.
        try await eventually { await pty.finished }
        #expect(await !pty.graceful)
    }
}

@Test func refreshSetupAfterUsageIsIgnoredAndClosesPanelBeforeExit() async throws {
    let pty = FakeClaudePTY()
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 8)
    let task = Task { await refresher.refresh() }
    try await eventually { await pty.messages.count == 1 }
    await pty.emit("Press Enter to continue")
    #expect(await task.value == .failed("Claude 自动续期超时"))
    #expect(await pty.messages == ["/usage\r", "\u{1b}", "/exit\r"])
    #expect(await pty.graceful)
    #expect(await pty.finished)
}

@Test func expiryReaderOnlyDecodesExpiryAndZeroIsRefreshable() async throws {
    let data = Data(#"{"claudeAiOauth":{"expiresAt":0,"accessToken":{"unexpected":true},"refreshToken":{"unexpected":true}}}"#.utf8)
    let reader = ClaudeKeychainExpiryReader(executor: FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0))]))
    #expect(try await reader.expiry() == Date(timeIntervalSince1970: 0))
    #expect(ClaudeTerminalParser.result("refresh token expired") == .needsLogin)
}

@Test func refreshSingleFlight() async throws {
    let pty = FakeClaudePTY("")
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 6)
    async let first = refresher.refresh()
    try await eventually { await pty.starts == 1 }
    async let second = refresher.refresh(force: true)
    await pty.emit("Choose the text style")
    _ = await (first, second)
    #expect(await pty.starts == 1)
    #expect(await pty.finished)
}

func refreshCredential(expiry: Double) -> Data {
    Data("{\"claudeAiOauth\":{\"accessToken\":\"FAKE-ACCESS\",\"expiresAt\":\(expiry * 1000)}}".utf8)
}

@Test func usageZeroExpiredNearExpiryAnd401UseInteractiveRefresher() async throws {
    let clock = FakeQuotaClock(), fresh = clock.now().addingTimeInterval(28_800)
    for initialExpiry in [0.0, clock.now().timeIntervalSince1970 - 1, clock.now().timeIntervalSince1970 + 1200, fresh.timeIntervalSince1970] {
        let unauthorized = initialExpiry == fresh.timeIntervalSince1970
        let executor = FakeQuotaExecutor([.success(.init(stdout: refreshCredential(expiry: initialExpiry), exitCode: 0)),
            .success(.init(stdout: refreshCredential(expiry: fresh.timeIntervalSince1970), exitCode: 0))])
        let refresher = FakeClaudeRefresher([.refreshed(fresh)])
        let http = FakeUsageHTTP((unauthorized ? [.success(.init(statusCode: 401))] : []) + [.success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))])
        let client = ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil }),
            http: http, now: { clock.now() }, refresher: refresher)
        _ = try await client.fetchQuota()
        #expect(await refresher.calls == [unauthorized])
        #expect(await client.status().expiresAt == fresh)
        #expect(await executor.calls.allSatisfy { $0.executable.path == "/usr/bin/security" })
    }
}

@Test func usageRetryAfterBlocksEvenManualRetry() async throws {
    for header in ["436", "Fri, 15 Jan 2027 08:07:16 GMT"] {
        let clock = FakeQuotaClock()
        let interval = try #require(ClaudeOAuthUsageClient.retrySeconds(header, now: clock.now()))
        #expect(interval == 436)
        let executor = FakeQuotaExecutor(Array(repeating: .success(.init(stdout: try quotaFixture("credentials.json"), exitCode: 0)), count: 2))
        let http = FakeUsageHTTP([.success(.init(statusCode: 429, retryAfter: header)), .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))])
        let client = ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil }),
            http: http, now: { clock.now() }, refresher: FakeClaudeRefresher())
        _ = try? await client.fetchQuota()
        await client.retryConnection()
        clock.advance(interval - 0.1)
        _ = try? await client.fetchQuota()
        #expect(await http.requests.count == 1)
        clock.advance(0.1)
        _ = try await client.fetchQuota()
        #expect(await http.requests.count == 2)
    }
    let date = Date(timeIntervalSince1970: 0)
    #expect(ClaudeOAuthUsageClient.retrySeconds("Thu, 01 Jan 1970 00:07:16 GMT", now: date) == 436)
}

@Test func usageFailureBackoffAndSetupManualRetry() async throws {
    for result: ClaudeRefreshResult in [.failed("fixture"), .needsUserSetup("fixture"), .needsLogin] {
        let clock = FakeQuotaClock()
        let executor = FakeQuotaExecutor(Array(repeating: .success(.init(stdout: refreshCredential(expiry: 0), exitCode: 0)), count: 12))
        let refresher = FakeClaudeRefresher([result])
        let client = ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil }),
            http: FakeUsageHTTP([]), now: { clock.now() }, refresher: refresher)
        _ = try? await client.fetchQuota()
        if case .failed = result {
            for (index, delay) in [120.0, 300, 900].enumerated() {
                clock.advance(delay - 1); _ = try? await client.fetchQuota()
                #expect(await refresher.calls.count == index + 1)
                clock.advance(1); _ = try? await client.fetchQuota()
                #expect(await refresher.calls.count == index + 2)
            }
        } else {
            clock.advance(1800); _ = try? await client.fetchQuota()
            #expect(await refresher.calls.count == 2)
            await client.retryConnection(); _ = try? await client.fetchQuota()
            #expect(await refresher.calls.count == 3)
        }
    }
}

@Test func usageSuccessCooldownAndChangedCredentialsReleaseSetup() async throws {
    let clock = FakeQuotaClock(), fresh = clock.now().addingTimeInterval(28_800)
    let zero = Result<QuotaCommandOutput, QuotaError>.success(.init(stdout: refreshCredential(expiry: 0), exitCode: 0))
    let valid = Result<QuotaCommandOutput, QuotaError>.success(.init(stdout: refreshCredential(expiry: fresh.timeIntervalSince1970), exitCode: 0))
    let executor = FakeQuotaExecutor([zero, valid, valid, valid, valid])
    let refresher = FakeClaudeRefresher([.refreshed(fresh)])
    let http = FakeUsageHTTP([.success(.init(statusCode: 200, data: try quotaFixture("claude-full.json"))),
        .success(.init(statusCode: 401)), .success(.init(statusCode: 401)),
        .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))])
    let client = ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil }),
        http: http, now: { clock.now() }, refresher: refresher)
    _ = try await client.fetchQuota()
    clock.advance(1799)
    _ = try? await client.fetchQuota()
    #expect(await refresher.calls.count == 1)
    clock.advance(1)
    _ = try await client.fetchQuota()
    #expect(await refresher.calls.count == 2)

    for missing in [false, true] {
        let executor = FakeQuotaExecutor([missing ? .success(.init(stdout: Data(), exitCode: 44)) : zero, valid])
        let refresher = FakeClaudeRefresher([.needsUserSetup("fixture")])
        let client = ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil }),
            http: FakeUsageHTTP([.success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))]),
            now: { clock.now() }, refresher: refresher)
        _ = try? await client.fetchQuota()
        #expect(await client.status().requiresUserAction)
        _ = try await client.fetchQuota()
        #expect(await !client.status().requiresUserAction)
        #expect(await refresher.calls.count == 1)
    }
}

private actor RefreshStatusProvider: ClaudeConnectionProviding {
    nonisolated let agent: ProviderID = .claude
    private var calls = 0
    func retryConnection() {}
    func fetchQuota() async throws -> QuotaSnapshot { try await fetchQuota(onStatus: { _ in }) }
    func fetchQuota(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot {
        calls += 1
        if calls > 1 {
            var status = ClaudeConnectionStatus(); status.isRefreshing = true
            await onStatus(status)
            try await Task.sleep(for: .seconds(60))
        }
        return quotaSample()
    }
}

@Test func servicePublishesRenewalWithoutClearingQuota() async throws {
    let clock = FakeQuotaClock(), provider = RefreshStatusProvider()
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 0 })
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.snapshot == quotaSample())
    await service.refreshNow(agent: .claude)
    let update = await iterator.next()
    #expect(update?.claudeConnection?.isRefreshing == true)
    #expect(update?.snapshot == quotaSample())
    #expect(update?.health == .stale(lastSuccess: quotaSample().fetchedAt))
    await service.stop()
}

@Test func incompleteMenuPromptIsNeverTreatedAsInput() async throws {
    let pty = FakeClaudePTY("❯")
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 6)
    let task = Task { await refresher.refresh() }
    try await eventually { await pty.starts == 1 }
    await pty.emit(" 1. Light\nChoose the text style")
    if case .needsUserSetup = await task.value {} else { Issue.record("Expected setup") }
    #expect(await pty.messages.isEmpty)
}

@Test func alreadyFreshAndMissingExecutableDoNotStartPTY() async {
    for fresh in [false, true] {
        let pty = FakeClaudePTY()
        let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([fresh ? Date().addingTimeInterval(7200) : .distantPast]),
            makePTY: { pty }, locate: { nil })
        let result = await refresher.refresh()
        if fresh { #expect(result == .alreadyFresh) }
        else if case .needsUserSetup = result {} else { Issue.record("Expected missing CLI setup") }
        #expect(await pty.starts == 0)
        #expect(await pty.finished)
    }
}

@Test func refreshSetupDuringSettlingRevokesInputBeforeUsage() async throws {
    let pty = FakeClaudePTY()
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 8)
    let task = Task { await refresher.refresh() }
    try await eventually { await pty.starts == 1 }
    try await Task.sleep(for: .milliseconds(50))
    await pty.emit("\nClaude\u{1b}[8Gin\u{1b}[11GChrome\u{1b}[18Gextension\u{1b}[28Gdetected")
    if case .needsUserSetup = await task.value {} else { Issue.record("Expected setup") }
    #expect(await pty.messages.isEmpty)
    #expect(await pty.finished)
    #expect(await !pty.graceful)
}

@Test func refreshErasedPromptCannotUseStaleReadiness() async throws {
    let pty = FakeClaudePTY(handwrittenClaudePrompt + "\u{1b}[2J\u{1b}[HUnknown screen")
    let refresher = ClaudeCLIRefresher(expiryReader: FakeClaudeExpiry([.distantPast]), makePTY: { pty },
        locate: { URL(fileURLWithPath: "/fixture/claude") }, timeout: 5.5)
    if case .failed = await refresher.refresh() {} else { Issue.record("Expected timeout") }
    #expect(await pty.messages.isEmpty)
    #expect(await !pty.graceful)
}
