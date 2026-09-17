import Foundation
import Testing
@testable import IslandCore

@Test func absentCredentialsNeverInvokeInjectedRefresherAcrossRetries() async throws {
    let clock = FakeQuotaClock(), refresher = FakeClaudeRefresher()
    let executor = FakeQuotaExecutor(Array(repeating: .success(.init(stdout: Data(), exitCode: 44)), count: 4))
    let credentials = ClaudeCredentialStore(executor: executor, readFallback: { nil })
    let http = FakeUsageHTTP([])
    let client = ClaudeOAuthUsageClient(credentialsPresent: { false }, credentials: credentials, http: http,
        now: { clock.now() }, refresher: refresher, clock: clock)
    for _ in 0..<4 {
        await #expect(throws: QuotaError.notConfigured(ClaudeCredentialStore.loginMessage)) { try await client.fetchQuota() }
        await client.retryConnection(); clock.advance(1800)
    }
    #expect(await refresher.calls.isEmpty)
    #expect(await http.requests.isEmpty)
    #expect(await !client.status().isRefreshing)
    #expect(await !client.status().isRecovering)
}

@Test(arguments: ["expired", "unauthorized", "proactive"]) func removedCredentialsBlockEveryRecoveryRoute(route: String) async throws {
    let clock = FakeQuotaClock(), refresher = FakeClaudeRefresher()
    let expiry = clock.now().addingTimeInterval(route == "expired" ? -1 : 600)
    let credentials = ClaudeCredentialStore(executor: FakeQuotaExecutor([
        .success(.init(stdout: refreshCredential(expiry: expiry.timeIntervalSince1970), exitCode: 0))]),
        now: { clock.now() }, readFallback: { nil })
    let http = FakeUsageHTTP([.success(.init(statusCode: route == "unauthorized" ? 401 : 200, data: try quotaFixture("claude-full.json")))])
    let client = ClaudeOAuthUsageClient(credentialsPresent: { false }, credentials: credentials, http: http,
        now: { clock.now() }, refresher: refresher, clock: clock)
    _ = try? await client.fetchQuota()
    #expect(await refresher.calls.isEmpty)
    #expect(await !client.status().isRefreshing)
}

@Test func nativeRefresherDoesNotLocateOrStartCLIWithoutCredentials() async {
    let pty = FakeClaudePTY()
    let refresher = ClaudeCLIRefresher(credentialsPresent: { false }, expiryReader: FakeClaudeExpiry([.distantPast]),
        makePTY: { pty }, locate: { Issue.record("Must not locate CLI"); return nil })
    #expect(await refresher.refresh(force: true) == .needsLogin)
    #expect(await pty.messages.isEmpty)
    #expect(await pty.starts == 0)
}

@Test(arguments: [false, true]) func nativeRefresherStartsWhenCredentialPresenceIsUnknown(force: Bool) async {
    // The terminal can still recognize login failure without submitting any input.
    let pty = FakeClaudePTY("oauth session expired and could not be refreshed")
    let refresher = ClaudeCLIRefresher(credentialsPresent: { nil }, expiryReader: FakeClaudeExpiry([.distantPast]),
        makePTY: { pty }, locate: { URL(fileURLWithPath: "/fixture/claude") })
    #expect(await refresher.refresh(force: force) == .needsLogin)
    #expect(await pty.starts == 1)
    #expect(await pty.messages.isEmpty)
    #expect(await pty.finished)
}

@Test(arguments: ["expired", "unauthorized", "proactive"]) func unknownCredentialPresenceDoesNotBlockOAuthRecovery(route: String) async throws {
    let clock = FakeQuotaClock(), refresher = FakeClaudeRefresher()
    let expiry = clock.now().addingTimeInterval(route == "expired" ? -1 : 600)
    let credentials = ClaudeCredentialStore(executor: FakeQuotaExecutor([
        .success(.init(stdout: refreshCredential(expiry: expiry.timeIntervalSince1970), exitCode: 0))]),
        now: { clock.now() }, readFallback: { nil })
    let http = FakeUsageHTTP([.success(.init(statusCode: route == "unauthorized" ? 401 : 200, data: try quotaFixture("claude-full.json")))])
    let client = ClaudeOAuthUsageClient(credentialsPresent: { nil }, credentials: credentials, http: http,
        now: { clock.now() }, refresher: refresher, clock: clock)
    _ = try? await client.fetchQuota()
    #expect(await refresher.calls.count == 1)
    #expect(await client.status().credentialsMissing != true)
    #expect(await !client.status().requiresUserAction)
}

private actor ToggleDetector: ProviderDetecting {
    var result = ProviderDetection(installed: [.claude: true, .codex: true], claudeCredentialsPresent: false)
    func detect() -> ProviderDetection { result }
    func set(_ result: ProviderDetection) { self.result = result }
}
private actor ToggleQuota: QuotaProviding {
    nonisolated let agent: ProviderID
    private(set) var calls = 0
    init(_ id: ProviderID) { agent = id }
    func fetchQuota() -> QuotaSnapshot { calls += 1; return quotaSample(agent) }
}
private actor ToggleSessions: SessionProviding {
    nonisolated let agent: ProviderID
    var model: String
    private(set) var calls = 0
    init(_ id: ProviderID, model: String) { agent = id; self.model = model }
    func currentSessions(now: Date) -> [AgentSession] {
        calls += 1
        return [.init(agent: agent, sessionId: "fixture", title: "测试", model: model, phase: .thinking, lastActivityAt: now)]
    }
    nonisolated func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
    func setModel(_ value: String) { model = value }
}

@MainActor @Test func runtimeHotUpdatesServicesAndDetectsBackendBeforeQuotaStarts() async throws {
    let detector = ToggleDetector(), claude = ToggleQuota(.claude), codex = ToggleQuota(.codex)
    let claudeSessions = ToggleSessions(.claude, model: "glm-fixture"), codexSessions = ToggleSessions(.codex, model: "gpt-fixture")
    let clock = FakeQuotaClock()
    let quota = QuotaService(providers: [claude, codex], clock: clock)
    let sessions = SessionService(providers: [claudeSessions, codexSessions])
    let store = IslandStore(providerDetector: detector, quotaService: quota, sessionService: sessions)
    await store.start()
    #expect(store.quotaProviderIDs == [.codex])
    #expect(store.sessionProviderIDs == [.claude, .codex])
    #expect(await claude.calls == 0)
    try await providerEventually { await codex.calls == 1 }
    store.providerOverrides = [.claude: false, .codex: false]
    try await providerEventually { await sessions.latestUpdate()?.sessions.isEmpty == true }
    #expect(store.displaySessions.isEmpty && !store.anyWorking)
    await store.refreshNow()
    #expect(!store.isRefreshing)
    #expect(await claude.calls == 0)
    #expect(await codex.calls == 1)
    store.providerOverrides = [:]
    await detector.set(.init(installed: [.claude: true], claudeCredentialsPresent: true))
    await store.detectProviders()
    try await providerEventually { await claude.calls == 1 }
    #expect(store.visibleProviderIDs == [.claude])
    #expect(store.quotaProviderIDs == [.claude])
    await claudeSessions.setModel("claude-fixture")
    await sessions.refreshNow()
    await detector.set(.init(installed: [.claude: true], claudeCredentialsPresent: false))
    await store.detectProviders()
    #expect(store.quotaProviderIDs == [.claude])
    await store.stop()
    #expect(clock.pending == 0)
}

@MainActor private func providerEventually(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await predicate())
}

@MainActor @Test func runtimeBootstrapsInactiveBackendBeforeQuotaAndClearsItAfterLogin() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let transcript = try fixture.write(try claudeLine("assistant", message: ["model": "glm-4.6"]),
        ".claude/projects/p/inactive.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-46 * 60), transcript)
    let source = ToggleQuota(.claude), quotaClock = FakeQuotaClock(), detectionClock = FakeQuotaClock()
    let quota = QuotaService(providers: [source], clock: quotaClock)
    let sessions = SessionService(providers: [ClaudeSessionProvider(paths: fixture.paths,
        liveness: FixtureLiveness(pids: []))], clock: { sessionTestNow })
    let store = IslandStore(providerDetector: ProviderDetector(home: fixture.root, diagnosticHome: true),
        providerClock: detectionClock, quotaService: quota, sessionService: sessions)
    await store.start()
    #expect(store.sessions.isEmpty)
    #expect(store.latestClaudeModel == "glm-4.6")
    #expect(store.quotaProviderIDs.isEmpty)
    #expect(store.sessionProviderIDs == [.claude])
    #expect(await source.calls == 0)
    try fixture.write("synthetic-presence-only", ".claude/.credentials.json")
    await store.detectProviders()
    #expect(store.quotaProviderIDs == [.claude])
    try await providerEventually { await source.calls == 1 }
    await store.stop()
    #expect(quotaClock.pending == 0)
    #expect(detectionClock.pending == 0)
}

@MainActor @Test func automaticDetectionRunsAtStartupEveryFiveMinutesAndExplicitWake() async throws {
    let detector = ToggleDetector(), detectionClock = FakeQuotaClock(), quotaClock = FakeQuotaClock()
    await detector.set(.init(installed: [:], claudeCredentialsPresent: false))
    let source = ToggleQuota(.codex)
    let quota = QuotaService(providers: [source], clock: quotaClock)
    let sessions = SessionService(providers: [ToggleSessions(.codex, model: "gpt-fixture")])
    let store = IslandStore(providerDetector: detector, providerClock: detectionClock, quotaService: quota, sessionService: sessions)
    await store.start()
    #expect(store.visibleProviderIDs.isEmpty)
    try await providerEventually { detectionClock.pending == 1 }
    #expect(detectionClock.sleeps == [300])
    await detector.set(.init(installed: [.codex: true], claudeCredentialsPresent: false))
    detectionClock.advance(299)
    #expect(store.visibleProviderIDs.isEmpty)
    detectionClock.advance(1)
    try await providerEventually { store.visibleProviderIDs == [.codex] }
    try await providerEventually { detectionClock.pending == 1 }
    #expect(detectionClock.sleeps == [300, 300])
    await detector.set(.init(installed: [:], claudeCredentialsPresent: false))
    await store.detectProviders() // AppDelegate invokes this on wake and unlock.
    #expect(store.visibleProviderIDs.isEmpty)
    await store.stop()
    try await providerEventually { detectionClock.pending == 0 }
}
