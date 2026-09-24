import Foundation
import Testing
@testable import IslandCore

@Test func quotaSuspensionStopsQueriesAndPreservesSubscriptionOnWake() async throws {
    let clock = FakeQuotaClock(), provider = SequenceQuotaProvider([.success(quotaSample())])
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 0 })
    var iterator = await service.updates().makeAsyncIterator()
    await service.setSuspended(true)
    await service.start()
    await service.refreshNow()
    #expect(await provider.count == 0)
    await service.setSuspended(false)
    #expect(await iterator.next()?.health == .ok)
    try await eventually { clock.pending == 1 }
    await service.setSuspended(true)
    #expect(clock.pending == 0)
    clock.advance(10000)
    await service.refreshNow()
    #expect(await provider.count == 1)
    await service.setSuspended(false)
    #expect(await iterator.next()?.health == .ok)
    #expect(await provider.count == 2)
    await service.stop()
    #expect(await iterator.next() == nil)
}

@Test func serviceIndependentSchedulesAndStop() async throws {
    let clock = FakeQuotaClock()
    let claude = SequenceQuotaProvider([.success(quotaSample())])
    let codex = SequenceQuotaProvider(agent: .codex, [.success(quotaSample(.codex))])
    let service = QuotaService(providers: [claude, codex], intervals: [.claude: 60, .codex: 120], clock: clock, jitter: { 0 })
    let stream = await service.updates(), log = QuotaUpdateLog()
    let consumer = Task { for await value in stream { await log.append(value) } }
    await service.start()
    await service.start()
    try await eventually { clock.sleeps.count == 2 }
    #expect(clock.sleeps.sorted() == [60, 120])
    #expect(await claude.count == 1)
    #expect(await codex.count == 1)
    clock.advance(59)
    #expect(await claude.count == 1)
    clock.advance(1)
    try await eventually { clock.sleeps.count == 3 }
    #expect(await claude.count == 2)
    #expect(await codex.count == 1)
    clock.advance(60)
    try await eventually { clock.sleeps.count == 5 }
    #expect(await claude.count == 3)
    #expect(await codex.count == 2)
    await service.stop()
    await consumer.value
    #expect(clock.pending == 0)
    clock.advance(10000)
    #expect(await claude.count == 3)
    #expect(await codex.count == 2)
    #expect(await log.values.count == 5)
}

@Test func serviceBackoffHealthAndRecovery() async throws {
    let clock = FakeQuotaClock(), snapshot = quotaSample()
    let provider = SequenceQuotaProvider([.failure(.transient("first")), .success(snapshot),
        .failure(.transient("temporary")), .failure(.transient("temporary")), .failure(.transient("temporary")),
        .failure(.transient("temporary")), .failure(.notConfigured("连接 Claude")),
        .failure(.unauthorized("重新登录")), .success(snapshot)])
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 0 })
    let stream = await service.updates(), log = QuotaUpdateLog()
    let consumer = Task { for await value in stream { await log.append(value) } }
    await service.start()
    let expected = [240.0, 120, 240, 480, 600, 600, 300, 600, 120]
    for (index, delay) in expected.enumerated() {
        try await eventually { clock.sleeps.count == index + 1 }
        #expect(clock.sleeps[index] == delay)
        if index < expected.count - 1 { clock.advance(delay) }
    }
    try await eventually { await log.values.count == expected.count }
    let updates = await log.values
    #expect(updates[0].snapshot == nil)
    #expect(updates[0].health == .failed(message: "first"))
    #expect(updates[1].health == .ok)
    #expect(updates[2].snapshot == snapshot)
    #expect(updates[2].health == .stale(lastSuccess: snapshot.fetchedAt))
    #expect(updates[6].snapshot == snapshot)
    #expect(updates[6].health == .needsSetup(message: "连接 Claude"))
    #expect(updates[7].health == .needsSetup(message: "重新登录"))
    #expect(updates[8].health == .ok)
    await service.stop(); await consumer.value
    #expect(clock.pending == 0)
}

@Test func serviceRefreshSelectedAllAndWhileStopped() async throws {
    let clock = FakeQuotaClock()
    let claude = SequenceQuotaProvider([.success(quotaSample())])
    let codex = SequenceQuotaProvider(agent: .codex, [.success(quotaSample(.codex))])
    let service = QuotaService(providers: [claude, codex], clock: clock, jitter: { 0 })
    await service.start()
    try await eventually { clock.pending == 2 }
    await service.refreshNow(agent: .claude)
    try await eventually { clock.sleeps.count == 3 }
    #expect(await claude.count == 2)
    #expect(await codex.count == 1)
    #expect(clock.pending == 2)
    await service.refreshNow()
    try await eventually { clock.sleeps.count == 5 }
    #expect(await claude.count == 3)
    #expect(await codex.count == 2)
    await service.stop()
    let stream = await service.updates(), log = QuotaUpdateLog()
    let consumer = Task { for await update in stream { await log.append(update) } }
    await service.refreshNow(agent: .codex)
    try await eventually { await codex.count == 3 }
    try await eventually { await log.values.count == 3 }
    #expect(clock.pending == 0)
    #expect(clock.sleeps.count == 5)
    await service.stop(); await consumer.value
}

@Test func serviceJitterConfigurationAndSetupRetry() async throws {
    for jitter in [-1.0, 1] {
        let clock = FakeQuotaClock()
        let provider = SequenceQuotaProvider([.success(quotaSample())])
        let service = QuotaService(providers: [provider], intervals: [.claude: 100], clock: clock, jitter: { jitter })
        await service.start()
        try await eventually { clock.pending == 1 }
        #expect(abs((clock.sleeps.first ?? 0) - (100 + jitter * 10)) < 0.000001)
        await service.stop()
    }
    let clock = FakeQuotaClock()
    let provider = SequenceQuotaProvider([.failure(.notConfigured("未连接"))])
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 1 })
    let stream = await service.updates()
    var iterator = stream.makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.health == .needsSetup(message: "未连接"))
    try await eventually { clock.pending == 1 }
    #expect(clock.sleeps == [300])
    await service.stop()
    #expect(await iterator.next() == nil)
}

private actor CancellableQuotaProvider: QuotaProviding {
    nonisolated let agent: ProviderID = .claude
    private(set) var calls = 0
    private(set) var cancellations = 0
    func fetchQuota() async throws -> QuotaSnapshot {
        calls += 1
        do { try await Task.sleep(for: .seconds(3600)) }
        catch { cancellations += 1; throw error }
        return quotaSample()
    }
}

private actor UncooperativeQuotaProvider: QuotaProviding {
    nonisolated let agent: ProviderID
    private(set) var calls = 0
    private var pending: [CheckedContinuation<QuotaSnapshot, any Error>] = []

    init(agent: ProviderID = .claude) { self.agent = agent }

    func fetchQuota() async throws -> QuotaSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func releaseAll() {
        let continuations = pending
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}

@Test func serviceCancelsInflightOnRefreshAndStop() async throws {
    let provider = CancellableQuotaProvider(), clock = FakeQuotaClock()
    let service = QuotaService(providers: [provider], clock: clock)
    await service.start()
    try await eventually { await provider.calls == 1 }
    await service.refreshNow()
    try await eventually { await provider.calls == 2 }
    #expect(await provider.cancellations == 1)
    await service.stop()
    #expect(await provider.cancellations == 2)
    #expect(clock.pending == 0)
    await service.start()
    try await eventually { await provider.calls == 3 }
    await service.stop()
    #expect(await provider.cancellations == 3)
}

@Test func refreshTimeoutRelaunchesStuckProviderWithoutBlockingOthers() async throws {
    let stuck = UncooperativeQuotaProvider()
    let codex = SequenceQuotaProvider(agent: .codex, [.success(quotaSample(.codex))])
    let clock = FakeQuotaClock()
    let service = QuotaService(providers: [stuck, codex], clock: clock,
                               workerCancellationTimeout: 0.2, jitter: { 0 })
    await service.start()
    try await eventually {
        let stuckCalls = await stuck.calls
        let codexCalls = await codex.count
        return stuckCalls == 1 && codexCalls == 1
    }

    let started = ContinuousClock.now
    let refresh = Task { await service.refreshNow() }
    try await eventually { await codex.count == 2 }
    #expect(await stuck.calls == 1)
    await refresh.value
    let elapsed = started.duration(to: .now)

    #expect(elapsed < .seconds(1))
    try await eventually { await stuck.calls == 2 }
    #expect(await service.activeWorkerIDs() == [.claude, .codex])

    await service.stop()
    await stuck.releaseAll()
}

@Test func lifecycleOperationsAlwaysReconcileEnabledWorkers() async throws {
    let claude = SequenceQuotaProvider([.success(quotaSample())])
    let codex = SequenceQuotaProvider(agent: .codex, [.success(quotaSample(.codex))])
    let service = QuotaService(providers: [claude, codex], clock: FakeQuotaClock(),
                               workerCancellationTimeout: 0.05, jitter: { 0 })
    await service.start()
    try await eventually { await service.activeWorkerIDs() == [.claude, .codex] }
    await service.start()
    await service.setEnabledProviders([.claude, .codex])
    #expect(await service.activeWorkerIDs() == [.claude, .codex])

    await service.setSuspended(true)
    #expect(await service.activeWorkerIDs().isEmpty)
    await service.refreshNow()
    await service.setEnabledProviders([.claude])
    await service.setSuspended(false)
    try await eventually { await service.activeWorkerIDs() == [.claude] }

    await service.refreshNow(agent: .codex)
    #expect(await service.activeWorkerIDs() == [.claude])
    await service.setEnabledProviders([.codex, .claude])
    try await eventually { await service.activeWorkerIDs() == [.claude, .codex] }
    await service.refreshNow()
    #expect(await service.activeWorkerIDs() == [.claude, .codex])

    await service.setSuspended(true)
    await service.setEnabledProviders([.codex])
    await service.refreshNow(agent: .codex)
    await service.setSuspended(false)
    try await eventually { await service.activeWorkerIDs() == [.codex] }
    await service.stop()
}

@Test func quotaWatchdogRelaunchesStaleWorkerAndRecordsProvider() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let provider = UncooperativeQuotaProvider()
    let clock = FakeQuotaClock()
    let diagnostics = ClaudeDiagnostics(directory: directory)
    let service = QuotaService(providers: [provider], intervals: [.claude: 30], clock: clock,
                               diagnostics: diagnostics, workerCancellationTimeout: 0.05,
                               watchdogPollInterval: 0.01, jitter: { 0 })
    await service.start()
    try await eventually { await provider.calls == 1 }

    clock.advance(601)
    try await eventually { await provider.calls == 2 }
    let log = await diagnostics.recentLines().joined(separator: "\n")
    #expect(log.contains("watchdogRelaunch"))
    #expect(log.contains("claude"))
    #expect(await service.activeWorkerIDs() == [.claude])

    await service.stop()
    await provider.releaseAll()
}

@Test func serviceMultipleSubscribersReceiveCachedUpdate() async throws {
    let provider = SequenceQuotaProvider([.success(quotaSample())]), clock = FakeQuotaClock()
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 0 })
    await service.start()
    try await eventually { clock.pending == 1 }
    let stream1 = await service.updates(), stream2 = await service.updates()
    var first = stream1.makeAsyncIterator(), second = stream2.makeAsyncIterator()
    #expect(await first.next()?.snapshot == quotaSample())
    #expect(await second.next()?.snapshot == quotaSample())
    await service.stop()
    #expect(await first.next() == nil)
    #expect(await second.next() == nil)
}

@Test func serviceLongSuccessIntervalIsConfigurable() async throws {
    let clock = FakeQuotaClock(), provider = SequenceQuotaProvider([.success(quotaSample())])
    let service = QuotaService(providers: [provider], intervals: [.claude: 900], clock: clock, jitter: { 0 })
    await service.start()
    try await eventually { clock.pending == 1 }
    #expect(clock.sleeps == [900])
    await service.stop()
}

@Test func serviceIntervalHotUpdateReschedulesWorkers() async throws {
    let provider = SequenceQuotaProvider([.success(quotaSample())])
    let clock = FakeQuotaClock()
    let service = QuotaService(providers: [provider], clock: clock, jitter: { 0 })
    await service.start()
    try await eventually { clock.sleeps.last == 120 }
    await service.setInterval(30)
    try await eventually { clock.sleeps.last == 30 }
    #expect(await provider.count == 2)
    await service.setInterval(30)
    #expect(await provider.count == 2)
    await service.stop()
    #expect(clock.pending == 0)
}

private actor BootstrapQuotaProvider: InitialQuotaProviding {
    nonisolated let agent: ProviderID = .codex
    var cancelled = false
    func initialQuota() async -> QuotaSnapshot? { quotaSample(.codex) }
    func fetchQuota() async throws -> QuotaSnapshot {
        do { try await Task.sleep(for: .seconds(20)) }
        catch { cancelled = true; throw error }
        return quotaSample(.codex)
    }
}

@Test func localQuotaBootstrapDoesNotWaitForAppServerAndStopsCleanly() async throws {
    let provider = BootstrapQuotaProvider()
    let service = QuotaService(providers: [provider])
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    let timeout = Task { try await Task.sleep(for: .seconds(2)); await service.stop() }
    let update = await iterator.next()
    timeout.cancel()
    #expect(update?.snapshot?.agent == .codex)
    #expect(update?.health == .stale(lastSuccess: update?.snapshot?.fetchedAt ?? .distantPast))
    await service.stop()
    #expect(await provider.cancelled)
}
