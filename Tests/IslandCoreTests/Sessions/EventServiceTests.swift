import Foundation
import Testing
@testable import IslandCore

private func eventSession(_ phase: SessionPhase, id: String = "one", agent: AgentKind = .claude) -> AgentSession {
    AgentSession(agent: agent, sessionId: id, title: "会话", cwd: "/fixture/project", phase: phase,
                 turnStartedAt: sessionTestNow.addingTimeInterval(-20), lastActivityAt: sessionTestNow)
}

@Test func sessionEventsTransitionsSilenceAndDeduplication() {
    let working = eventSession(.runningTool)
    var waiting = eventSession(.waitingInput)
    waiting.turnEndedAt = sessionTestNow.addingTimeInterval(-5)
    #expect(detectSessionEvents(old: [], new: [waiting], now: sessionTestNow).isEmpty)
    #expect(detectSessionEvents(old: [working], new: [], now: sessionTestNow).isEmpty)
    #expect(detectSessionEvents(old: [working], new: [eventSession(.waitingInput, id: "new")], now: sessionTestNow).isEmpty)
    #expect(detectSessionEvents(old: [waiting], new: [waiting], now: sessionTestNow).isEmpty)
    let completion = detectSessionEvents(old: [working], new: [waiting], now: sessionTestNow)
    #expect(completion.first?.kind == .turnCompleted(duration: 15))
    #expect(completion.first?.sessionID == working.id)
    #expect(completion.first?.title == "会话 · 本轮完成")
    #expect(completion.first?.detail == "project")
    let attention = detectSessionEvents(old: [working], new: [eventSession(.waitingPermission)], now: sessionTestNow)
    let error = detectSessionEvents(old: [working], new: [eventSession(.error)], now: sessionTestNow)
    #expect(attention.first?.kind == .needsAttention(reason: "等待授权"))
    #expect(error.first?.kind == .failed(message: "出错"))
    var deduper = EventDeduper()
    #expect(deduper.filter(completion + completion, now: sessionTestNow).count == 1)
    #expect(deduper.filter(completion, now: sessionTestNow.addingTimeInterval(29)).isEmpty)
    #expect(deduper.filter(attention + error, now: sessionTestNow.addingTimeInterval(29)).count == 2)
    #expect(deduper.filter(completion, now: sessionTestNow.addingTimeInterval(30)).count == 1)
    let other = detectSessionEvents(old: [eventSession(.thinking, agent: .codex)], new: [eventSession(.waitingInput, agent: .codex)], now: sessionTestNow)
    #expect(deduper.filter(other, now: sessionTestNow.addingTimeInterval(30)).count == 1)
}

@Test func quotaEventsOnlyUpwardCrossings() {
    func snapshot(_ percent: Double) -> QuotaSnapshot {
        QuotaSnapshot(agent: .claude, windows: [QuotaWindow(id: "weekly", kind: .weekly, label: "本周", usedPercent: percent)], source: .mock, fetchedAt: sessionTestNow)
    }
    #expect(detectQuotaEvents(old: nil, new: snapshot(95)).isEmpty)
    #expect(detectQuotaEvents(old: snapshot(95), new: snapshot(20)).isEmpty)
    #expect(detectQuotaEvents(old: snapshot(70), new: snapshot(80)).isEmpty)
    #expect(detectQuotaEvents(old: snapshot(69), new: snapshot(70)).first?.kind == .quotaThreshold(windowID: "weekly", percent: 70))
    let events = detectQuotaEvents(old: snapshot(60), new: snapshot(95))
    #expect(events.count == 2)
    #expect(events.last?.title == "Claude 本周额度已用 90%")
    #expect(detectQuotaEvents(old: snapshot(89), new: snapshot(90)).count == 1)
}

private actor FixtureSessionProvider: SessionProviding {
    nonisolated let agent: AgentKind = .claude
    nonisolated let signals = AsyncStream<Set<String>>.makeStream()
    var phase: SessionPhase = .thinking
    var refreshCount = 0
    var dates: [Date] = []
    nonisolated func changes() -> AsyncStream<Set<String>> { signals.stream }
    func currentSessions(now: Date) async -> [AgentSession] {
        refreshCount += 1
        dates.append(now)
        return [eventSession(phase)]
    }
    func setPhase(_ value: SessionPhase) { phase = value }
}

@Test func sessionServiceRefreshEventsAndStop() async throws {
    let provider = FixtureSessionProvider()
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    let stream = await service.updates()
    var iterator = stream.makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.sessions.first?.phase == .thinking)
    #expect(await provider.refreshCount == 1)
    await service.start()
    #expect(await provider.refreshCount == 1)
    await provider.setPhase(.waitingInput)
    await service.refreshNow()
    let update = await iterator.next()
    #expect(update?.events.first?.kind == .turnCompleted(duration: 20))
    #expect(await provider.dates.allSatisfy { $0 == sessionTestNow })
    await service.stop()
    #expect(await iterator.next() == nil)
    let count = await provider.refreshCount
    provider.signals.continuation.yield([])
    await service.changed(agent: provider.agent, paths: [])
    await service.waitForPendingRefresh()
    #expect(await provider.refreshCount == count)
}

@Test func sessionServiceRespondsToChanges() async throws {
    let provider = FixtureSessionProvider()
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    let stream = await service.updates()
    var iterator = stream.makeAsyncIterator()
    await service.start()
    _ = await iterator.next()
    await provider.setPhase(.waitingPermission)
    provider.signals.continuation.yield([])
    // Bound a failed signal test without relying on real FSEvents, unavailable in this sandbox.
    let timeout = Task { try await Task.sleep(for: .seconds(2)); await service.stop() }
    let update = await iterator.next()
    timeout.cancel()
    #expect(update?.sessions.first?.phase == .waitingPermission)
    #expect(update?.events.count == 1)
    await service.stop()
}

private actor CancellableSessionProvider: SessionProviding {
    nonisolated let agent: AgentKind = .claude
    nonisolated let entered = AsyncStream<Void>.makeStream()
    nonisolated let terminated = AsyncStream<Void>.makeStream()
    var cancelled = false
    nonisolated func changes() -> AsyncStream<Set<String>> {
        let pair = AsyncStream<Set<String>>.makeStream()
        pair.continuation.onTermination = { _ in self.terminated.continuation.yield(()) }
        return pair.stream
    }
    func currentSessions(now: Date) async -> [AgentSession] {
        entered.continuation.yield(())
        do { try await Task.sleep(for: .seconds(10)) }
        catch { cancelled = true }
        return [eventSession(.waitingInput)]
    }
}

@Test func sessionServiceStopCancelsInFlightAndSubscription() async throws {
    let provider = CancellableSessionProvider()
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    let updates = await service.updates()
    var iterator = updates.makeAsyncIterator()
    var entered = provider.entered.stream.makeAsyncIterator()
    var terminated = provider.terminated.stream.makeAsyncIterator()
    let start = Task { await service.start() }
    _ = await entered.next()
    await service.stop()
    await start.value
    #expect(await provider.cancelled)
    #expect(await iterator.next() == nil)
    let timeout = Task {
        try await Task.sleep(for: .seconds(2))
        provider.terminated.continuation.finish()
    }
    #expect(await terminated.next() != nil)
    timeout.cancel()
}

private actor TokenSessionProvider: SessionProviding {
    nonisolated let agent: AgentKind = .codex
    var revision: String?
    var visible = true
    nonisolated func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
    func currentSessions(now: Date) -> [AgentSession] {
        guard visible else { return [] }
        var session = eventSession(.thinking, agent: .codex)
        session.tokenCountRevision = revision
        return [session]
    }
    func setRevision(_ value: String) { revision = value }
    func setVisible(_ value: Bool) { visible = value }
}

@Test func sessionServiceTokenSignalsExcludeInitialAndUnrelatedChanges() async {
    let provider = TokenSessionProvider()
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    await provider.setRevision("first")
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.codexTokenCountChanged == false)
    await service.refreshNow()
    #expect(await service.metrics.updatesPublished == 1)
    await provider.setRevision("second")
    await service.refreshNow()
    #expect(await iterator.next()?.codexTokenCountChanged == true)
    await provider.setVisible(false)
    await service.refreshNow()
    #expect(await iterator.next()?.codexTokenCountChanged == false)
    await provider.setVisible(true)
    await provider.setRevision("newly-discovered")
    await service.refreshNow()
    #expect(await iterator.next()?.codexTokenCountChanged == true)
    await service.stop()
}

@Test func sessionFileBurstPublishesAtMostTwicePerSecond() async {
    let provider = FixtureSessionProvider()
    let scheduler = ManualSessionScheduler()
    let service = SessionService(providers: [provider], clock: { sessionTestNow }, scheduler: scheduler)
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    _ = await iterator.next()
    let start = scheduler.now()
    await provider.setPhase(.waitingInput)
    for _ in 0..<100 { await service.changed(agent: provider.agent, paths: []) }
    await scheduler.waitForSleep(until: start.advanced(by: .milliseconds(500)))
    scheduler.advance(by: .milliseconds(499))
    #expect(await provider.refreshCount == 1)
    #expect(await service.metrics.updatesPublished == 1)
    scheduler.advance(by: .milliseconds(1))
    await service.waitForPendingRefresh()
    #expect(await iterator.next()?.sessions.first?.phase == .waitingInput)
    #expect(await provider.refreshCount == 2)
    #expect(await service.metrics.updatesPublished == 2)
    await provider.setPhase(.waitingPermission)
    for _ in 0..<100 { await service.changed(agent: provider.agent, paths: []) }
    await scheduler.waitForSleep(until: start.advanced(by: .seconds(1)))
    scheduler.advance(by: .milliseconds(499))
    #expect(await provider.refreshCount == 2)
    scheduler.advance(by: .milliseconds(1))
    await service.waitForPendingRefresh()
    #expect(await iterator.next()?.sessions.first?.phase == .waitingPermission)
    #expect(await provider.refreshCount == 3)
    await service.stop()
}
