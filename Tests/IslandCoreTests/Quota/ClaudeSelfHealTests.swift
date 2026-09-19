import Foundation
import Testing
@testable import IslandCore

private actor HealingEnvironment: QuotaCommandExecuting, ClaudeRefreshing {
    let clock: FakeQuotaClock
    var expiry: Date
    var mdat: Date
    var version = "1.0"
    var outcome: ClaudeRefreshResult = .needsUserSetup("fixture setup")
    private(set) var refreshes = 0
    private(set) var reads = 0
    init(clock: FakeQuotaClock, expiry: Date) { self.clock = clock; self.expiry = expiry; mdat = clock.now() }
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> QuotaCommandOutput {
        reads += 1
        return .init(stdout: refreshCredential(expiry: expiry.timeIntervalSince1970), exitCode: 0)
    }
    func refresh(force: Bool) -> ClaudeRefreshResult {
        refreshes += 1
        if case let .refreshed(date) = outcome, date > clock.now() { expiry = date; mdat = clock.now() }
        return outcome
    }
    func configure(_ result: ClaudeRefreshResult) { outcome = result }
    func externalRenewal() { expiry = clock.now().addingTimeInterval(28_800); mdat = clock.now().addingTimeInterval(1) }
    func changeVersion() { version = "2.0" }
    func modifyEntry() { mdat = mdat.addingTimeInterval(1) }
    func client(http: any UsageHTTPTransport, diagnostics: ClaudeDiagnostics = .disabled) -> ClaudeOAuthUsageClient {
        ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: ClaudeCredentialStore(executor: self, now: { self.clock.now() },
            diagnostics: diagnostics, readFallback: { nil }), http: http, now: { self.clock.now() }, refresher: self,
            clock: clock, diagnostics: diagnostics, modificationDate: { await self.mdat }, cliVersion: { await self.version })
    }
}

private func healingHTTP(_ count: Int = 5) throws -> FakeUsageHTTP {
    FakeUsageHTTP(Array(repeating: .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json"))), count: count))
}

private actor SignedOutRecoveryEnvironment: QuotaCommandExecuting {
    let clock: FakeQuotaClock
    private var signedIn = false
    private var modification: Date
    private(set) var credentialReads = 0
    private(set) var modificationReads = 0
    private(set) var cliVersionReads = 0
    init(clock: FakeQuotaClock) { self.clock = clock; modification = clock.now() }
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> QuotaCommandOutput {
        credentialReads += 1
        let data = signedIn
            ? refreshCredential(expiry: clock.now().addingTimeInterval(28_800).timeIntervalSince1970)
            : Data(#"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}"#.utf8)
        return .init(stdout: data, exitCode: 0)
    }
    func modificationDate() -> Date {
        modificationReads += 1
        return modification
    }
    func cliVersion() -> String {
        cliVersionReads += 1
        return "fixture-1.0"
    }
    func signIn() {
        signedIn = true
        modification = modification.addingTimeInterval(1)
    }
}

@Test func signedOutAttributePollingRecoversWithinThirtySecondsAndStopsUserAction() async throws {
    let clock = FakeQuotaClock(), environment = SignedOutRecoveryEnvironment(clock: clock)
    let http = try healingHTTP(2), refresher = FakeClaudeRefresher([.failed("must not run")])
    let credentials = ClaudeCredentialStore(executor: environment, now: { clock.now() }, readFallback: { nil })
    let client = ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: credentials, http: http,
        now: { clock.now() }, refresher: refresher, clock: clock,
        modificationDate: { await environment.modificationDate() },
        cliVersion: { await environment.cliVersion() })
    let service = QuotaService(providers: [ClaudeQuotaProvider(client: client)], intervals: [.claude: 600],
                               clock: clock, jitter: { 0 })
    let updates = QuotaUpdateLog(), stream = await service.updates()
    let reader = Task { for await value in stream { await updates.append(value) } }
    await service.start()
    try await eventually {
        let status = await client.status()
        return status.requiresUserAction && status.result == .needsLogin && clock.sleeps.contains(30)
    }
    #expect(await environment.credentialReads == 1)
    #expect(await environment.modificationReads == 1)
    #expect(await environment.cliVersionReads == 1)
    #expect(await refresher.calls.isEmpty)
    #expect(await http.requests.isEmpty)

    // An unchanged attribute poll does not request the keychain password value again.
    clock.advance(30)
    try await eventually { clock.sleeps.filter { $0 == 30 }.count == 2 }
    #expect(await environment.credentialReads == 1)
    #expect(await environment.modificationReads == 2)
    // No CLI probe runs during the signed-out 30-second poll.
    #expect(await environment.cliVersionReads == 1)
    await environment.signIn()
    clock.advance(30)
    try await eventually { await updates.values.last?.health == .ok }
    #expect(await environment.credentialReads == 2)
    #expect(await environment.modificationReads >= 3)
    #expect(await environment.cliVersionReads == 1)
    #expect(await http.requests.count == 1)
    #expect(await !client.status().requiresUserAction)
    #expect(await refresher.calls.isEmpty)
    // Once the signed-out state has cleared, the next fetch resumes the full environment check.
    _ = try await client.fetchQuota()
    #expect(await environment.cliVersionReads == 2)
    await service.stop(); await reader.value
}

@Test func sleepingAcrossExpiryWindowRecoversAndServiceReturnsOK() async throws {
    let clock = FakeQuotaClock()
    let environment = HealingEnvironment(clock: clock, expiry: clock.now().addingTimeInterval(3600))
    let client = await environment.client(http: try healingHTTP())
    _ = try await client.fetchQuota()
    #expect(await environment.refreshes == 0)
    clock.advance(10_800)
    await environment.configure(.refreshed(clock.now().addingTimeInterval(28_800)))
    let service = QuotaService(providers: [ClaudeQuotaProvider(client: client)], clock: clock, jitter: { 0 })
    let updates = QuotaUpdateLog()
    let stream = await service.updates()
    let reader = Task { for await update in stream { await updates.append(update) } }
    await service.start()
    try await eventually { await updates.values.last?.health == .ok }
    #expect(await environment.refreshes == 1)
    #expect(await client.status().isRecovering == false)
    await service.stop(); await reader.value
}

@Test func setupRetriesAfterThirtyMinutesAndEveryExternalTrigger() async throws {
    for trigger in ["time", "mdat", "cli", "manual", "wake"] {
        let clock = FakeQuotaClock()
        let environment = HealingEnvironment(clock: clock, expiry: .distantPast)
        let client = await environment.client(http: try healingHTTP())
        _ = try? await client.fetchQuota()
        #expect(await environment.refreshes == 1)
        #expect(await client.status().requiresUserAction)
        clock.advance(1799)
        _ = try? await client.fetchQuota()
        #expect(await environment.refreshes == 1)
        await environment.configure(.refreshed(clock.now().addingTimeInterval(28_800)))
        switch trigger {
        case "time": clock.advance(1)
        case "mdat": await environment.modifyEntry()
        case "cli": await environment.changeVersion()
        case "manual": await client.retryConnection()
        default:
            let service = QuotaService(providers: [ClaudeQuotaProvider(client: client)], clock: clock)
            await service.setSuspended(true); await service.start(); await service.setSuspended(false)
            try await eventually { await environment.refreshes == 2 }
            await service.stop()
        }
        _ = try await client.fetchQuota()
        #expect(await environment.refreshes == 2)
        #expect(await !client.status().requiresUserAction)
    }
}

@Test func externalRenewalUsesValidCredentialDespiteBlockedState() async throws {
    for result: ClaudeRefreshResult in [.needsUserSetup("fixture"), .needsLogin, .failed("fixture")] {
        let clock = FakeQuotaClock()
        let environment = HealingEnvironment(clock: clock, expiry: .distantPast)
        await environment.configure(result)
        let client = await environment.client(http: try healingHTTP())
        _ = try? await client.fetchQuota()
        await environment.externalRenewal()
        let snapshot = try await client.fetchQuota()
        #expect(snapshot.source == .claudeOAuth)
        #expect(await environment.refreshes == 1)
        #expect(await !client.status().requiresUserAction)
        #expect(await !client.status().isRecovering)
    }
}

@Test func validCredentialReachesHTTPBeforeProactiveRefresh() async throws {
    let clock = FakeQuotaClock(), http = try healingHTTP()
    let environment = HealingEnvironment(clock: clock, expiry: clock.now().addingTimeInterval(600))
    let refresher = HTTPFirstRefresher(http: http)
    let client = ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: ClaudeCredentialStore(executor: environment, now: { clock.now() }, readFallback: { nil }),
        http: http, now: { clock.now() }, refresher: refresher, clock: clock)
    _ = try await client.fetchQuota()
    #expect(await refresher.sawHTTP)
    _ = try await client.fetchQuota()
    #expect(await http.requests.count == 2)
    #expect(await !client.status().requiresUserAction)
}
private actor HTTPFirstRefresher: ClaudeRefreshing {
    let http: FakeUsageHTTP
    private(set) var sawHTTP = false
    init(http: FakeUsageHTTP) { self.http = http }
    func refresh(force: Bool) async -> ClaudeRefreshResult {
        sawHTTP = await !http.requests.isEmpty
        return .needsUserSetup("fixture")
    }
}

@Test func expiredFailuresRetryForeverAndUnverifiedSuccessDoesNotCoolDown() async throws {
    for result: ClaudeRefreshResult in [.failed("fixture"), .alreadyFresh, .refreshed(.distantPast)] {
        let clock = FakeQuotaClock()
        let environment = HealingEnvironment(clock: clock, expiry: Date(timeIntervalSince1970: 0))
        await environment.configure(result)
        let client = await environment.client(http: try healingHTTP())
        _ = try? await client.fetchQuota()
        for (index, delay) in [120.0, 300, 900, 1800, 1800, 1800].enumerated() {
            clock.advance(delay - 1); _ = try? await client.fetchQuota()
            #expect(await environment.refreshes == index + 1)
            clock.advance(1); _ = try? await client.fetchQuota()
            #expect(await environment.refreshes == index + 2)
        }
    }
}

@Test func successCooldownCannotPreventRecoveryAfterTokenExpires() async throws {
    let clock = FakeQuotaClock()
    let environment = HealingEnvironment(clock: clock, expiry: .distantPast)
    await environment.configure(.refreshed(clock.now().addingTimeInterval(60)))
    let client = await environment.client(http: try healingHTTP())
    _ = try await client.fetchQuota()
    clock.advance(61)
    await environment.configure(.refreshed(clock.now().addingTimeInterval(28_800)))
    _ = try await client.fetchQuota()
    #expect(await environment.refreshes == 2)
}

@Test func loginCopyRequiresExplicitFailureAndTwoAutomaticRetries() async throws {
    let clock = FakeQuotaClock()
    let environment = HealingEnvironment(clock: clock, expiry: .distantPast)
    await environment.configure(.needsLogin)
    let client = await environment.client(http: try healingHTTP())
    for attempt in 1...4 {
        _ = try? await client.fetchQuota()
        let status = await client.status()
        #expect(status.requiresUserAction == (attempt >= 3))
        #expect(status.recoveryMessage == (attempt >= 3 ? "Claude 登录已失效，请重新登录" : "正在自动恢复连接…"))
        clock.advance(1800)
    }
    #expect(await environment.refreshes == 4)
    #expect(ClaudeTerminalParser.result("network request could not be refreshed") == nil)
    var setup = ClaudeConnectionStatus(); setup.requiresUserAction = true; setup.result = .needsUserSetup("fixture")
    #expect(setup.recoveryMessage.contains("岛会每 30 分钟自动重试"))
}

private actor RacingCredentials: QuotaCommandExecuting {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    let data: Data
    init(_ data: Data) { self.data = data }
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async -> QuotaCommandOutput {
        reads += 1
        if reads == 1 { await withCheckedContinuation { pending = $0 } }
        return .init(stdout: data, exitCode: 0)
    }
    var waiting: Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
}
@Test func invalidationDuringCredentialIOReadsAgainWithoutUnauthorized() async throws {
    let clock = FakeQuotaClock()
    let executor = RacingCredentials(refreshCredential(expiry: clock.now().addingTimeInterval(7200).timeIntervalSince1970))
    let store = ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil })
    let task = Task { try await store.credentials() }
    try await eventually { await executor.waiting }
    await store.invalidate(); await executor.release()
    #expect(try await task.value.expiresAt == clock.now().addingTimeInterval(7200))
    #expect(await executor.reads == 2)
}

/// Ignores cancellation until released by test teardown, modeling a non-cooperative dependency.
private actor HangingHTTP: UsageHTTPTransport {
    let body: Data
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var cancelled = false
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async -> UsageHTTPResponse {
        calls += 1
        if calls == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { pending = $0 }
            } onCancel: { Task { await self.markCancelled() } }
        }
        return .init(statusCode: 200, data: body)
    }
    var waiting: Bool { pending != nil }
    func markCancelled() { cancelled = true }
    func release() { pending?.resume(); pending = nil }
}
private actor HangingRefresher: ClaudeRefreshing {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var cancelled = false
    func refresh(force: Bool) async -> ClaudeRefreshResult {
        calls += 1
        if calls == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { pending = $0 }
            } onCancel: { Task { await self.markCancelled() } }
        }
        return .needsUserSetup("fixture")
    }
    var waiting: Bool { pending != nil }
    func markCancelled() { cancelled = true }
    func release() { pending?.resume(); pending = nil }
}
@Test func fetchWatchdogDetachesHungHTTPAndNextFetchWorks() async throws {
    let clock = FakeQuotaClock(), directory = try quotaTestDirectory()
    let logger = ClaudeDiagnostics(directory: directory)
    let environment = HealingEnvironment(clock: clock, expiry: clock.now().addingTimeInterval(7200))
    let http = HangingHTTP(body: try quotaFixture("claude-full.json"))
    let client = await environment.client(http: http, diagnostics: logger)
    let task = Task { try await client.fetchQuota() }
    try await eventually { await http.waiting && clock.pending > 0 }
    clock.advance(60)
    await #expect(throws: QuotaError.transient("Claude 额度查询超时，将自动重试")) { try await task.value }
    try await eventually { await http.cancelled }
    _ = try await client.fetchQuota()
    #expect(await http.calls == 2)
    #expect(await logger.recentLines().contains { $0.contains("watchdog") && $0.contains("fetch") })
    await http.release()
}
@Test func hungInjectedRefresherCannotFreezeFetchOrOverwriteReplacement() async throws {
    let clock = FakeQuotaClock(), environment = HealingEnvironment(clock: FakeQuotaClock(), expiry: .distantPast)
    let refresher = HangingRefresher()
    let client = ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: ClaudeCredentialStore(executor: environment, now: { clock.now() }, readFallback: { nil }),
        http: try healingHTTP(), now: { clock.now() }, refresher: refresher, clock: clock)
    let task = Task { try await client.fetchQuota() }
    try await eventually { await refresher.waiting && clock.pending >= 2 }
    clock.advance(60)
    _ = try? await task.value
    try await eventually { await refresher.cancelled }
    await environment.externalRenewal()
    _ = try await client.fetchQuota()
    #expect(await !client.status().isRecovering)
    await refresher.release()
    _ = try await client.fetchQuota()
    #expect(await !client.status().requiresUserAction)
}

@Test func nativeRefresherWatchdogClearsItsOwnInFlight() async throws {
    let clock = FakeQuotaClock(), reader = HangingExpiry(clock: FakeQuotaClock())
    let pty = FakeClaudePTY()
    let refresher = ClaudeCLIRefresher(credentialsPresent: { true }, expiryReader: reader, makePTY: { pty }, locate: { nil }, clock: clock)
    let task = Task { await refresher.refresh() }
    try await eventually { await reader.waiting && clock.pending > 0 }
    clock.advance(60)
    if case .failed = await task.value {} else { Issue.record("Expected watchdog failure") }
    #expect(await refresher.refresh() == .alreadyFresh)
    await reader.release()
}
private actor HangingExpiry: ClaudeExpiryReading {
    let clock: FakeQuotaClock
    private var pending: CheckedContinuation<Void, Never>?
    private var reads = 0
    init(clock: FakeQuotaClock) { self.clock = clock }
    func expiry() async -> Date? {
        reads += 1
        if reads == 1 { await withCheckedContinuation { pending = $0 } }
        return clock.now().addingTimeInterval(7200)
    }
    var waiting: Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
}

@Test func diagnosticsAreBoundedAndNeverContainFixtureSecrets() async throws {
    let directory = try quotaTestDirectory(), clock = FakeQuotaClock()
    let logger = ClaudeDiagnostics(directory: directory, limit: 4096)
    let secret = "DO-NOT-LOG-FAKE-ACCESS", refresh = "DO-NOT-LOG-FAKE-REFRESH"
    let payload = Data("{\"claudeAiOauth\":{\"accessToken\":\"\(secret)\",\"refreshToken\":\"\(refresh)\",\"expiresAt\":0}}".utf8)
    let store = ClaudeCredentialStore(executor: FakeQuotaExecutor(Array(repeating: .success(.init(stdout: payload, exitCode: 0)), count: 4)),
        now: { clock.now() }, diagnostics: logger, readFallback: { nil })
    let client = ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: store, http: FakeUsageHTTP([.failure(.transient(secret))]), now: { clock.now() },
        refresher: FakeClaudeRefresher([.failed(secret + refresh)]), clock: clock, diagnostics: logger)
    _ = try? await client.fetchQuota()
    let initial = await logger.recentLines().joined(separator: "\n")
    #expect(initial.contains("credentialRead")); #expect(initial.contains("refresherEnd"))
    #expect(!initial.contains(secret)); #expect(!initial.contains(refresh))
    for _ in 0..<100 { await logger.record(.fetchStart, at: clock.now()) }
    for name in ["claude.jsonl", "claude.previous.jsonl"] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect(data.count <= 4096)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        #expect(!String(decoding: data, as: UTF8.self).contains(refresh))
    }
    #expect(await logger.recentLines().count <= 200)
    let large = ClaudeDiagnostics(directory: try quotaTestDirectory())
    for index in 0..<220 { await large.record(.httpEnd, at: clock.now(), statusCode: index) }
    let tail = await large.recentLines()
    #expect(tail.count == 200)
    #expect(tail.first?.contains("\"statusCode\":20") == true)
}

@Test func keychainModificationProbeNeverRequestsPassword() async throws {
    let data = Data("attributes:\n    \"mdat\"<timedate>=\"20260914172400Z\"\n".utf8)
    let executor = FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0))])
    let reader = ClaudeKeychainModificationReader(executor: executor)
    #expect(try await reader.modificationDate() == DateParsing.iso8601("2026-09-14T17:24:00Z"))
    #expect(await executor.calls.first?.arguments == ["find-generic-password", "-s", "Claude Code-credentials"])
}

@Test func serviceRetainsStaleQuotaAndDoesNotSleepPastRecoveryDeadline() async throws {
    let clock = FakeQuotaClock()
    let provider = RecoveryDeadlineProvider(clock: clock)
    let service = QuotaService(providers: [provider], intervals: [.claude: 600], clock: clock, jitter: { 0 })
    let updates = QuotaUpdateLog(), stream = await service.updates()
    let reader = Task { for await value in stream { await updates.append(value) } }
    await service.start()
    try await eventually {
        let update = await updates.values.last
        return clock.pending == 1 && update?.health == .ok
    }
    #expect(await updates.values.last?.health == .ok)
    clock.advance(600)
    try await eventually { clock.pending == 1 && clock.sleeps.last == 120 }
    let waiting = await updates.values.last
    #expect(waiting?.snapshot == quotaSample())
    #expect(waiting?.health == .stale(lastSuccess: quotaSample().fetchedAt))
    #expect(waiting?.claudeConnection?.recoveryMessage == ClaudeOAuthUsageClient.recoveringMessage)
    clock.advance(120)
    try await eventually { await provider.calls == 3 }
    await service.stop(); await reader.value
}
private actor RecoveryDeadlineProvider: ClaudeConnectionProviding {
    nonisolated let agent = ProviderID.claude
    let clock: FakeQuotaClock
    private(set) var calls = 0
    init(clock: FakeQuotaClock) { self.clock = clock }
    func retryConnection() {}
    func fetchQuota() async throws -> QuotaSnapshot { try await fetchQuota(onStatus: { _ in }) }
    func fetchQuota(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot {
        calls += 1
        if calls == 2 {
            var status = ClaudeConnectionStatus(); status.isRecovering = true
            status.nextRetryAt = clock.now().addingTimeInterval(120)
            await onStatus(status)
            throw QuotaError.transient(ClaudeOAuthUsageClient.recoveringMessage)
        }
        return quotaSample()
    }
}

@Test func diagnosticsSanitizeHTTPBodiesErrorsAndHealthMessages() async throws {
    let clock = FakeQuotaClock(), directory = try quotaTestDirectory()
    let logger = ClaudeDiagnostics(directory: directory)
    let secret = "FAKE-HTTP-SECRET"
    let data = Data("{\"claudeAiOauth\":{\"accessToken\":\"\(secret)\",\"expiresAt\":2000000000000}}".utf8)
    let client = ClaudeOAuthUsageClient(credentialsPresent: { true }, credentials: ClaudeCredentialStore(executor: FakeQuotaExecutor([
        .success(.init(stdout: data, exitCode: 0))]), now: { clock.now() }, diagnostics: logger, readFallback: { nil }),
        http: FakeUsageHTTP([.success(.init(statusCode: 503, data: Data(secret.utf8))), .failure(.transient(secret))]),
        now: { clock.now() }, refresher: FakeClaudeRefresher(), clock: clock, diagnostics: logger)
    _ = try? await client.fetchQuota(); _ = try? await client.fetchQuota()
    let provider = SequenceQuotaProvider([.failure(.transient(secret)), .success(quotaSample())])
    let service = QuotaService(providers: [provider], clock: clock, diagnostics: logger)
    await service.start()
    try await eventually { clock.pending == 1 }
    await service.refreshNow()
    try await eventually { await provider.count == 2 }
    await service.stop()
    let lines = await logger.recentLines().joined(separator: "\n")
    #expect(lines.contains("\"statusCode\":503"))
    #expect(lines.contains("healthChange")); #expect(lines.contains("\"previous\":\"failed\""))
    #expect(!lines.contains(secret))
}

@Test func manualRetryCancelsHungFetchBeforeResettingRecoveryGates() async throws {
    let clock = FakeQuotaClock()
    let environment = HealingEnvironment(clock: clock, expiry: clock.now().addingTimeInterval(7200))
    let http = HangingHTTP(body: try quotaFixture("claude-full.json"))
    let client = await environment.client(http: http)
    let first = Task { try await client.fetchQuota() }
    try await eventually { await http.waiting }
    await client.retryConnection()
    await #expect(throws: CancellationError.self) { try await first.value }
    _ = try await client.fetchQuota()
    #expect(await http.calls == 2)
    try await eventually { await http.cancelled }
    await http.release()
}
