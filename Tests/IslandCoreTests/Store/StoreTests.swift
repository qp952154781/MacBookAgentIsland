import Foundation
import Testing
@testable import IslandCore

private actor StoreQuotaService: QuotaServicing {
    var continuation: AsyncStream<QuotaUpdate>.Continuation?
    var starts = 0
    var stops = 0
    var refreshes: [AgentKind?] = []
    var interval: TimeInterval = 0
    func updates() -> AsyncStream<QuotaUpdate> {
        let pair = AsyncStream<QuotaUpdate>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func start() { starts += 1 }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
    func refreshNow(agent: AgentKind?) { refreshes.append(agent) }
    func setInterval(_ seconds: TimeInterval) { interval = seconds }
    func emit(_ update: QuotaUpdate) { continuation?.yield(update) }
}
private actor StoreSessionService: SessionServicing {
    var continuation: AsyncStream<SessionUpdate>.Continuation?
    var starts = 0
    var stops = 0
    var refreshes = 0
    var window: TimeInterval = 0
    func updates() -> AsyncStream<SessionUpdate> {
        let pair = AsyncStream<SessionUpdate>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func start() { starts += 1 }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
    func refreshNow() { refreshes += 1 }
    func setActiveWindow(_ seconds: TimeInterval) { window = seconds }
    func emit(_ update: SessionUpdate) { continuation?.yield(update) }
}

@MainActor private func storeEventually(_ predicate: @MainActor () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await predicate()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await predicate())
}

@MainActor @Test func storeWiringFirstLoadRefreshIsolationAndLifecycle() async throws {
    let quota = StoreQuotaService(), sessions = StoreSessionService()
    let clock = FakeQuotaClock()
    let store = IslandStore(quotaService: quota, sessionService: sessions, clock: { clock.now() })
    #expect(store.quotas.isEmpty && store.health.isEmpty)
    await store.start(); await store.start()
    #expect(await quota.starts == 1)
    #expect(await sessions.starts == 1)
    var snapshot = quotaSample(at: clock.now())
    snapshot.windows[0].usedPercent = 95
    await quota.emit(.init(agent: .claude, snapshot: snapshot, health: .ok))
    await quota.emit(.init(agent: .codex, snapshot: nil, health: .failed(message: "测试失败")))
    try await storeEventually { store.health.count == 2 }
    #expect(store.headline(for: .claude)?.usedPercent == 95)
    #expect(store.headline(for: .codex) == nil)
    #expect(store.lastRefresh == clock.now())
    await store.refreshNow()
    #expect(store.isRefreshing)
    #expect(await quota.refreshes.count == 1)
    #expect(await sessions.refreshes == 1)
    await quota.emit(.init(agent: .codex, snapshot: quotaSample(.codex), health: .ok))
    try await storeEventually { store.health[.codex] == .ok }
    #expect(store.isRefreshing)
    await quota.emit(.init(agent: .claude, snapshot: snapshot, health: .needsSetup(message: "请登录")))
    try await storeEventually { !store.isRefreshing }
    #expect(store.headline(for: .claude) == nil)
    #expect(store.quotas[.codex] != nil)
    await store.configure(interval: 120, activeWindow: 900)
    #expect(await quota.interval == 120)
    #expect(await sessions.window == 900)
    await store.stop()
    #expect(!store.isRunning)
    #expect(await quota.stops == 1)
    #expect(await sessions.stops == 1)
    await store.start()
    #expect(await quota.starts == 2)
    await store.stop()
}

@MainActor @Test func storeUpdatesAndTokenRefreshThrottle() async throws {
    let quota = StoreQuotaService(), sessions = StoreSessionService(), clock = FakeQuotaClock()
    let store = IslandStore(quotaService: quota, sessionService: sessions, clock: { clock.now() })
    await store.start()
    var snapshot = quotaSample()
    snapshot.windows[0].usedPercent = 40
    store.warningThreshold = 50; store.criticalThreshold = 80
    await quota.emit(.init(agent: .claude, snapshot: snapshot, health: .ok))
    try await storeEventually { store.quotas[.claude] != nil }
    snapshot.windows[0].usedPercent = 85
    await quota.emit(.init(agent: .claude, snapshot: snapshot, health: .ok))
    try await storeEventually { store.quotas[.claude]?.windows[0].usedPercent == 85 }
    let session = AgentSession(agent: .codex, sessionId: "fixture", title: "测试", phase: .thinking, lastActivityAt: clock.now())
    let event = IslandEvent(agent: .codex, sessionID: session.id, title: "完成", kind: .turnCompleted(duration: 3), date: clock.now())
    await sessions.emit(.init(sessions: [session], events: [event]))
    try await storeEventually { store.sessions.count == 1 }
    await sessions.emit(.init(sessions: [session], events: [event], codexTokenCountChanged: true))
    try await storeEventually { await quota.refreshes.count == 1 }
    clock.advance(59)
    var next = session; next.title = "59秒"
    await sessions.emit(.init(sessions: [next], events: [event], codexTokenCountChanged: true))
    try await storeEventually { store.sessions.first?.title == "59秒" }
    #expect(await quota.refreshes.count == 1)
    clock.advance(1)
    await sessions.emit(.init(sessions: [next], events: [], codexTokenCountChanged: true))
    try await storeEventually { await quota.refreshes.count == 2 }
    #expect(await quota.refreshes.allSatisfy { $0 == .codex })
    await store.stop()
}

@MainActor @Test func settingsDefaultsAndImmediateApplication() {
    let settings = AppSettings()
    let store = IslandStore()
    #expect(settings.refreshInterval == 120 && settings.activeMinutes == 30)
    #expect(settings.expansionMethod == .hover && !settings.useMainScreen && !settings.showInFullscreen)
    settings.onChange = { settings.apply(to: store) }
    settings.wingWidth = 100
    settings.warningThreshold = 55
    settings.criticalThreshold = 85
    #expect(store.layoutConfig.wingWidth == 100)
    #expect(store.warningThreshold == 55 && store.criticalThreshold == 85)
    settings.onChange = nil
}

@MainActor @Test func storeReleaseCancelsOwnedServices() async throws {
    let quota = StoreQuotaService(), sessions = StoreSessionService()
    var store: IslandStore? = IslandStore(quotaService: quota, sessionService: sessions)
    weak let released = store
    await store?.start()
    store = nil
    try await storeEventually { released == nil }
    try await storeEventually { await quota.stops > 0 }
    #expect(await sessions.stops > 0)
}

@MainActor @Test func firstLoadMetricsExcludeEmptySubscriptionAndUseMonotonicClock() async throws {
    let quota = StoreQuotaService(), sessions = StoreSessionService()
    let started = ContinuousClock.now.advanced(by: .milliseconds(-100))
    let store = IslandStore(quotaService: quota, sessionService: sessions,
                            clock: { Date(timeIntervalSince1970: -1e100) }, processStarted: started)
    await store.start()
    #expect(store.firstSessionMs == nil && !store.sessionsLoaded)
    await quota.emit(.init(agent: .codex, snapshot: nil, health: .failed(message: "fixture")))
    try await storeEventually { store.health[.codex] != nil }
    #expect(store.firstQuotaMs == nil)
    await quota.emit(.init(agent: .codex, snapshot: quotaSample(.codex), health: .ok))
    await sessions.emit(.init(sessions: [], events: []))
    try await storeEventually { store.sessionsLoaded && store.firstQuotaMs != nil }
    #expect((store.firstQuotaMs ?? 0) >= 100)
    #expect((store.firstSessionMs ?? 0) >= 100)
    let first = store.firstQuotaMs
    await quota.emit(.init(agent: .codex, snapshot: quotaSample(.codex), health: .ok))
    await store.stop()
    #expect(store.firstQuotaMs == first)
}
