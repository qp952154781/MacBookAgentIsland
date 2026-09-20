import Foundation
import Testing
@testable import IslandCore

private actor SafetyEnvironment: QuotaCommandExecuting, ClaudeRefreshing {
    let clock: FakeQuotaClock
    private var expiry: Date
    private var modification: Date
    private var results: [ClaudeRefreshResult]
    private(set) var refreshForces: [Bool] = []

    init(clock: FakeQuotaClock, expiry: Date, results: [ClaudeRefreshResult]) {
        self.clock = clock; self.expiry = expiry; self.results = results
        modification = clock.now().addingTimeInterval(-10)
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) -> QuotaCommandOutput {
        .init(stdout: refreshCredential(expiry: expiry.timeIntervalSince1970), exitCode: 0)
    }

    func refresh(force: Bool) -> ClaudeRefreshResult {
        refreshForces.append(force)
        let result = results.count > 1 ? results.removeFirst() : results.first ?? .failed("fixture")
        modification = clock.now()
        if case let .refreshed(date) = result { expiry = date }
        return result
    }

    func modificationDate() -> Date { modification }
    func externalRewrite() { modification = clock.now() }
}

private actor SafetyReachability: ClaudeReachabilityChecking {
    let clock: FakeQuotaClock
    private var values: [Bool]
    private(set) var checkedAt: [Date] = []

    init(clock: FakeQuotaClock, values: [Bool]) { self.clock = clock; self.values = values }
    func isReachable() -> Bool {
        checkedAt.append(clock.now())
        return values.count > 1 ? values.removeFirst() : values.first ?? false
    }
}

private func safetyClient(clock: FakeQuotaClock, environment: SafetyEnvironment,
                          http: any UsageHTTPTransport, reachability: any ClaudeReachabilityChecking,
                          diagnostics: ClaudeDiagnostics = .disabled) -> ClaudeOAuthUsageClient {
    ClaudeOAuthUsageClient(credentialsPresent: { true },
        credentials: ClaudeCredentialStore(executor: environment, now: { clock.now() }, readFallback: { nil }),
        http: http, now: { clock.now() }, refresher: environment, clock: clock, diagnostics: diagnostics,
        reachability: reachability, modificationDate: { await environment.modificationDate() })
}

@Test func wakeGraceReachabilityAndSingleAttemptPerResumeCycle() async throws {
    let clock = FakeQuotaClock(), directory = try quotaTestDirectory()
    let diagnostics = ClaudeDiagnostics(directory: directory)
    let future = clock.now().addingTimeInterval(28_800)
    let environment = SafetyEnvironment(clock: clock, expiry: .distantPast, results: [.refreshed(future)])
    let reachability = SafetyReachability(clock: clock, values: [true])
    let http = FakeUsageHTTP([.success(.init(statusCode: 200, data: try quotaFixture("claude-full.json"))),
                              .success(.init(statusCode: 401))])
    let client = safetyClient(clock: clock, environment: environment, http: http,
                              reachability: reachability, diagnostics: diagnostics)

    await client.noteSuspension(); await client.noteResume()
    clock.advance(44)
    _ = try? await client.fetchQuota()
    #expect(await environment.refreshForces.isEmpty)
    #expect(await reachability.checkedAt.isEmpty)
    #expect(await client.status().nextRetryAt == clock.now().addingTimeInterval(1))
    var log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(log.contains("\"event\":\"refresherSkip\"") && log.contains("\"category\":\"wakeGrace\""))

    clock.advance(2)
    _ = try await client.fetchQuota()
    #expect(await environment.refreshForces == [false])
    #expect(await reachability.checkedAt == [clock.now()])

    // A 401 arriving right after a successful refresh must not relaunch the CLI: the
    // credential it just wrote is still valid, so the recovery cooldown holds it back.
    _ = try? await client.fetchQuota()
    #expect(await environment.refreshForces == [false])
    log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(log.contains("\"event\":\"recoverSkip\""))
}

/// A successful refresh must not consume the wake cycle: a Mac that stays awake past the
/// token's ~8 hour lifetime still needs the next refresh, and only failures close the cycle.
@Test func successfulRefreshLeavesTheWakeCycleOpenForTheNextExpiry() async throws {
    let clock = FakeQuotaClock()
    let first = clock.now().addingTimeInterval(28_800)
    let second = clock.now().addingTimeInterval(57_600)
    let environment = SafetyEnvironment(clock: clock, expiry: .distantPast,
                                        results: [.refreshed(first), .refreshed(second)])
    let reachability = SafetyReachability(clock: clock, values: [true])
    let http = FakeUsageHTTP([.success(.init(statusCode: 200, data: try quotaFixture("claude-full.json"))),
                              .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))])
    let client = safetyClient(clock: clock, environment: environment, http: http, reachability: reachability)

    await client.noteSuspension(); await client.noteResume()
    clock.advance(46)
    _ = try await client.fetchQuota()
    #expect(await environment.refreshForces == [false])

    // Same wake cycle, the refreshed token has now expired in turn.
    clock.advance(28_800)
    _ = try await client.fetchQuota()
    #expect(await environment.refreshForces == [false, false])
    #expect(await client.status().expiresAt == second)
}

@Test func unreachableNetworkRechecksEveryFifteenSecondsForAtMostTenMinutes() async throws {
    let clock = FakeQuotaClock(), diagnostics = ClaudeDiagnostics(directory: try quotaTestDirectory())
    let environment = SafetyEnvironment(clock: clock, expiry: .distantPast, results: [.failed("must not run")])
    let reachability = SafetyReachability(clock: clock, values: [false])
    let client = safetyClient(clock: clock, environment: environment, http: FakeUsageHTTP([]),
                              reachability: reachability, diagnostics: diagnostics)

    for index in 0...40 {
        _ = try? await client.fetchQuota()
        if index < 40 {
            #expect(await client.status().nextRetryAt == clock.now().addingTimeInterval(15))
            clock.advance(15)
        }
    }
    let checks = await reachability.checkedAt
    #expect(checks.count == 41)
    #expect(zip(checks, checks.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 15 })
    #expect(await client.status().nextRetryAt == nil)
    #expect(await environment.refreshForces.isEmpty)
    let log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(log.contains("\"event\":\"refresherSkip\"") && log.contains("\"category\":\"network\""))
}

@Test func failedRefreshBacksOffForceRecoveryForThirtyMinutes() async throws {
    let clock = FakeQuotaClock(), directory = try quotaTestDirectory()
    let diagnostics = ClaudeDiagnostics(directory: directory)
    let future = clock.now().addingTimeInterval(28_800)
    let environment = SafetyEnvironment(clock: clock, expiry: future,
        results: [.failed("fixture failure"), .refreshed(future.addingTimeInterval(3600))])
    let http = FakeUsageHTTP([
        .success(.init(statusCode: 401)), .success(.init(statusCode: 401)),
        .success(.init(statusCode: 401)), .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))
    ])
    let client = safetyClient(clock: clock, environment: environment, http: http,
                              reachability: SafetyReachability(clock: clock, values: [true]), diagnostics: diagnostics)

    _ = try? await client.fetchQuota()
    #expect(await environment.refreshForces == [true])
    clock.advance(29 * 60)
    _ = try? await client.fetchQuota()
    #expect(await environment.refreshForces == [true])
    var log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(log.contains("\"event\":\"refresherSkip\"") && log.contains("\"category\":\"backoff\""))
    #expect(log.contains("\"reason\":\"failure\""))

    clock.advance(2 * 60)
    _ = try await client.fetchQuota()
    #expect(await environment.refreshForces == [true, true])
    log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(!log.contains("fixture failure"))
}

@Test func manualRetryAndExternalCredentialRewriteClearFailureBackoff() async throws {
    for trigger in ["manual", "credential"] {
        let clock = FakeQuotaClock(), future = clock.now().addingTimeInterval(28_800)
        let environment = SafetyEnvironment(clock: clock, expiry: future,
            results: [.failed("fixture"), .refreshed(future.addingTimeInterval(3600))])
        let http = FakeUsageHTTP([
            .success(.init(statusCode: 401)), .success(.init(statusCode: 401)),
            .success(.init(statusCode: 200, data: try quotaFixture("claude-full.json")))
        ])
        let client = safetyClient(clock: clock, environment: environment, http: http,
                                  reachability: SafetyReachability(clock: clock, values: [true]))
        _ = try? await client.fetchQuota()
        if trigger == "manual" { await client.retryConnection() }
        else { clock.advance(2); await environment.externalRewrite() }
        _ = try await client.fetchQuota()
        #expect(await environment.refreshForces == [true, true])
    }
}

@Test func disabledAutoRefreshBlocksExpiredAndForcePathsAndShowsDisabledMessage() async throws {
    for force in [false, true] {
        let clock = FakeQuotaClock(), diagnostics = ClaudeDiagnostics(directory: try quotaTestDirectory())
        let expiry = force ? clock.now().addingTimeInterval(28_800) : Date.distantPast
        let environment = SafetyEnvironment(clock: clock, expiry: expiry, results: [.failed("must not run")])
        let responses: [Result<UsageHTTPResponse, QuotaError>] = force
            ? [.success(.init(statusCode: 401)), .success(.init(statusCode: 401))] : []
        let client = safetyClient(clock: clock, environment: environment, http: FakeUsageHTTP(responses),
                                  reachability: SafetyReachability(clock: clock, values: [true]), diagnostics: diagnostics)
        await client.setAutoRefreshEnabled(false)
        _ = try? await client.fetchQuota()
        await client.retryConnection()
        _ = try? await client.fetchQuota()
        let status = await client.status()
        #expect(!status.autoRefreshEnabled)
        #expect(status.isRecovering)
        #expect(status.recoveryMessage == ClaudeConnectionStatus.automaticRefreshDisabledMessage)
        #expect(await environment.refreshForces.isEmpty)
        let log = await diagnostics.recentLines().joined(separator: "\n")
        #expect(log.contains("\"event\":\"refresherSkip\"") && log.contains("\"category\":\"disabled\""))
    }
}

@MainActor private final class AutoRefreshDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor @Test func claudeAutoRefreshDefaultsOnAndPersistsRoundTrip() {
    let defaults = AutoRefreshDefaults()
    #expect(AppSettings(defaults: defaults).claudeAutoRefresh)
    let settings = AppSettings(defaults: defaults)
    settings.claudeAutoRefresh = false
    #expect(defaults.object(forKey: "claudeAutoRefresh") as? Bool == false)
    #expect(!AppSettings(defaults: defaults).claudeAutoRefresh)
    let store = IslandStore()
    AppSettings(defaults: defaults).apply(to: store)
    #expect(!store.claudeAutoRefresh)
    settings.claudeAutoRefresh = true
    #expect(AppSettings(defaults: defaults).claudeAutoRefresh)
}
