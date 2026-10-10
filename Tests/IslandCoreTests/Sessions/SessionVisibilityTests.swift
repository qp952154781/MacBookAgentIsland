import Foundation
import Testing
@testable import IslandCore

private func windowSession(_ phase: SessionPhase, agent: ProviderID = .claude, id: String = "fixture",
                           age: TimeInterval = 16 * 60, alive: Bool? = true) -> AgentSession {
    AgentSession(agent: agent, sessionId: id, title: "脱敏会话", phase: phase,
                 lastActivityAt: sessionTestNow.addingTimeInterval(-age), isAlive: alive)
}

@Test(arguments: ProviderRegistry.orderedIDs, SessionPhase.allCases)
func sessionWindowRequiresConfirmedLivenessToExemptWorkingPhases(agent: ProviderID, phase: SessionPhase) {
    let liveness: [Bool?] = [true, false, nil]
    for alive in liveness {
        let ages: [TimeInterval] = [14 * 60, 15 * 60, 16 * 60, 90 * 60, 120 * 60, 120 * 60 + 1, 10 * 3600]
        for age in ages {
            let session = windowSession(phase, agent: agent, age: age, alive: alive)
            let decision = SessionVisibilityPolicy.decisions(for: [session], now: sessionTestNow, activeWindow: 900)[session.id]
            let working = phase.isWorking || phase == .waitingPermission
            let shown = working ? (alive == true || age <= (alive == nil ? 7200 : 900)) : age <= 900
            #expect(decision?.shown == shown)
            if !shown {
                #expect(decision?.reason == (working && alive == nil ? .staleWorking : .idleExpired))
            } else if working {
                #expect(decision?.reason == (phase == .waitingPermission ? .waitingPermission : .working))
            }
        }
    }
}

@Test(arguments: [900.0, 3600.0, 3 * 3600.0])
func unknownWorkingExpirationUsesLargerOfActiveWindowAndTwoHours(activeWindow: TimeInterval) {
    let cap = max(activeWindow, 7200)
    for phase in SessionPhase.allCases.filter({ $0.isWorking || $0 == .waitingPermission }) {
        let recent = windowSession(phase, agent: .codex, age: 90 * 60, alive: nil)
        let boundary = windowSession(phase, agent: .codex, id: "boundary", age: cap, alive: nil)
        let stale = windowSession(phase, agent: .codex, id: "stale", age: cap + 1, alive: nil)
        let decisions = SessionVisibilityPolicy.decisions(for: [recent, boundary, stale], now: sessionTestNow, activeWindow: activeWindow)
        #expect(decisions[recent.id]?.shown == true)
        #expect(decisions[boundary.id]?.shown == true)
        #expect(decisions[stale.id]?.shown == false)
        #expect(decisions[stale.id]?.reason == .staleWorking)
        #expect(SessionVisibilityPolicy.expiration(of: recent, activeWindow: activeWindow) == recent.lastActivityAt.addingTimeInterval(cap))
    }
}

@Test func codexThreeHourToolIsStaleWhileConfirmedLiveClaudeTenHourToolIsShown() {
    let codex = windowSession(.runningTool, agent: .codex, age: 3 * 3600, alive: nil)
    let live = windowSession(.runningTool, id: "live", age: 10 * 3600)
    let dead = windowSession(.runningTool, id: "dead", age: 20 * 60, alive: false)
    let decisions = SessionVisibilityPolicy.decisions(for: [codex, live, dead], now: sessionTestNow, activeWindow: 900)
    #expect(decisions[codex.id] == SessionVisibility(shown: false, reason: .staleWorking))
    #expect(decisions[live.id] == SessionVisibility(shown: true, reason: .working))
    #expect(decisions[dead.id] == SessionVisibility(shown: false, reason: .idleExpired))
}

@Test func displayLimitDoesNotConsumeSlotsForExpiredSessionsOrDropProtectedSessions() {
    let working = (0..<5).map { windowSession(.runningTool, id: "working-\($0)", age: 475 * 60) }
    let expired = (0..<55).map { windowSession(.idle, id: "expired-\($0)", age: 16 * 60) }
    let shown = SessionVisibilityPolicy.shownSessions(expired + working, now: sessionTestNow, activeWindow: 900)
    #expect(Set(shown.map(\.id)) == Set(working.map(\.id)))
    let recent = (0..<55).map { windowSession(.waitingInput, id: "recent-\($0)", age: Double($0)) }
    let permission = windowSession(.waitingPermission, id: "permission", age: 475 * 60)
    let capped = SessionVisibilityPolicy.decisions(for: recent + working + [permission], now: sessionTestNow, activeWindow: 900)
    #expect(capped.values.filter(\.shown).count == 50)
    #expect((working + [permission]).allSatisfy { capped[$0.id]?.shown == true })
    #expect(capped.values.filter { $0.reason == .sessionLimit }.count == 11)
    let allWorking = (0..<60).map { windowSession(.thinking, id: "all-working-\($0)") }
    #expect(SessionVisibilityPolicy.shownSessions(allWorking, now: sessionTestNow, activeWindow: 900).count == 60)
}

@Test func staleWorkingSessionsDoNotConsumeDisplaySlots() {
    let stale = (0..<55).map { windowSession(.runningTool, agent: .codex, id: "stale-\($0)", age: 3 * 3600, alive: nil) }
    let recent = (0..<50).map { windowSession(.waitingInput, agent: .codex, id: "recent-\($0)", age: Double($0), alive: nil) }
    let eligible = windowSession(.runningTool, agent: .codex, id: "eligible", age: 90 * 60, alive: nil)
    let decisions = SessionVisibilityPolicy.decisions(for: stale + recent + [eligible], now: sessionTestNow, activeWindow: 900)
    #expect(stale.allSatisfy { decisions[$0.id] == SessionVisibility(shown: false, reason: .staleWorking) })
    #expect(decisions[eligible.id] == SessionVisibility(shown: true, reason: .working))
    #expect(decisions.values.filter(\.shown).count == 50)
    #expect(decisions.values.filter { $0.reason == .sessionLimit }.count == 1)
}

private actor WindowProvider: SessionProviding {
    nonisolated let agent: ProviderID
    var values: [AgentSession]
    var scans = 0
    init(_ agent: ProviderID = .claude, values: [AgentSession]) { self.agent = agent; self.values = values }
    nonisolated func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
    func currentSessions(now: Date) -> [AgentSession] { scans += 1; return values }
    func replace(_ values: [AgentSession]) { self.values = values }
}

private func wallClock(_ scheduler: ManualSessionScheduler) -> @Sendable () -> Date {
    let origin = scheduler.now()
    return {
        let elapsed = origin.duration(to: scheduler.now()).components
        return sessionTestNow.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}

@Test(arguments: ProviderRegistry.orderedIDs)
func sessionAutomaticallyExpiresWithoutFileChangesOrProviderScans(agent: ProviderID) async {
    let scheduler = ManualSessionScheduler(), origin = scheduler.now()
    let provider = WindowProvider(agent, values: [windowSession(.waitingInput, agent: agent, age: 899)])
    let service = SessionService(providers: [provider], clock: wallClock(scheduler), scheduler: scheduler)
    await service.setActiveWindow(900)
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.sessions.count == 1)
    await scheduler.waitForSleep(until: origin.advanced(by: .milliseconds(1001)), tolerance: .milliseconds(1))
    scheduler.advance(by: .seconds(1))
    #expect(await service.latestUpdate()?.sessions.count == 1)
    scheduler.advance(by: .milliseconds(2))
    let update = await iterator.next()
    #expect(update?.sessions.isEmpty == true)
    #expect(update?.events.isEmpty == true)
    #expect(update?.codexTokenCountChanged == false)
    #expect(await provider.scans == 1)
    #expect(await service.nextExpirationAt == nil)
    await service.stop()
    #expect(await iterator.next() == nil)
}

@Test(arguments: ProviderRegistry.orderedIDs, [SessionPhase.runningTool, .waitingPermission])
func unknownWorkingAutomaticallyExpiresAtStaleCapWithoutProviderScans(agent: ProviderID, phase: SessionPhase) async {
    for activeWindow in [900.0, 3600.0, 10800.0] {
        let scheduler = ManualSessionScheduler(), origin = scheduler.now()
        let session = windowSession(phase, agent: agent, age: max(activeWindow, 7200) - 1, alive: nil)
        let provider = WindowProvider(agent, values: [session])
        let service = SessionService(providers: [provider], clock: wallClock(scheduler), scheduler: scheduler)
        await service.setActiveWindow(activeWindow)
        var iterator = await service.updates().makeAsyncIterator()
        await service.start()
        #expect(await iterator.next()?.sessions == [session])
        await scheduler.waitForSleep(until: origin.advanced(by: .milliseconds(1001)), tolerance: .milliseconds(1))
        scheduler.advance(by: .seconds(1))
        #expect(await service.latestUpdate()?.sessions == [session])
        scheduler.advance(by: .milliseconds(2))
        let update = await iterator.next()
        #expect(update?.sessions.isEmpty == true)
        #expect(update?.events.isEmpty == true)
        #expect(update?.codexTokenCountChanged == false)
        #expect(await provider.scans == 1)
        #expect(await service.nextExpirationAt == nil)
        await service.stop()
        #expect(await iterator.next() == nil)
    }
}

@Test func protectedExpiredAndEmptyListsScheduleNoExpirationRecheck() async {
    for values in [[], [windowSession(.idle)], SessionPhase.allCases.filter {
        $0.isWorking || $0 == .waitingPermission
    }.map { windowSession($0, id: $0.rawValue, age: 475 * 60) }] {
        let scheduler = ManualSessionScheduler()
        let provider = WindowProvider(values: values)
        let service = SessionService(providers: [provider], clock: { sessionTestNow }, scheduler: scheduler)
        await service.setActiveWindow(900)
        await service.start()
        #expect(await service.nextExpirationAt == nil)
        await service.stop()
    }
}

@Test func malformedFarFutureActivityCannotOverflowExpirationScheduler() async {
    let scheduler = ManualSessionScheduler()
    var session = windowSession(.waitingInput)
    session.lastActivityAt = Date(timeIntervalSince1970: 1e100)
    let provider = WindowProvider(values: [session])
    let service = SessionService(providers: [provider], clock: { sessionTestNow }, scheduler: scheduler)
    await service.start()
    #expect(await service.latestUpdate()?.sessions.count == 1)
    #expect(await service.nextExpirationAt == nil)
    await service.stop()
}

@Test func newWorkCancelsOldExpirationAndStopCancelsPendingDeadline() async {
    let scheduler = ManualSessionScheduler(), origin = scheduler.now()
    let provider = WindowProvider(values: [windowSession(.waitingInput, age: 899)])
    let service = SessionService(providers: [provider], clock: wallClock(scheduler), scheduler: scheduler)
    await service.setActiveWindow(900)
    await service.start()
    await scheduler.waitForSleep(until: origin.advanced(by: .milliseconds(1001)), tolerance: .milliseconds(1))
    await provider.replace([windowSession(.runningTool, age: 475 * 60)])
    await service.changed(agent: .claude, paths: ["/fixture/session.jsonl"])
    scheduler.advance(by: .milliseconds(500))
    await service.waitForPendingRefresh()
    #expect(await service.nextExpirationAt == nil)
    scheduler.advance(by: .seconds(1))
    #expect(await service.latestUpdate()?.sessions.first?.phase == .runningTool)
    await provider.replace([windowSession(.waitingInput, age: 0)])
    await service.changed(agent: .claude, paths: ["/fixture/session.jsonl"])
    await service.waitForPendingRefresh()
    #expect(await service.nextExpirationAt != nil)
    await service.stop()
    #expect(await service.nextExpirationAt == nil)
}

@Test func claudeParsesAllSixtyLiveSessionsBeforeApplyingExpiryAndLimit() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    for index in 0..<60 {
        let id = "fixture-\(index)"
        try fixture.write("{\"pid\":123,\"sessionId\":\"\(id)\",\"entrypoint\":\"claude-desktop\"}", ".claude/sessions/\(id).json")
        // Put the five working sessions behind all idle sessions in modification order.
        let working = index >= 55
        let text = working ? try claudeLine("user", message: ["content": "开始长任务"])
            : try claudeLine("assistant", message: ["stop_reason": "end_turn"])
        let file = try fixture.write(text, ".claude/projects/p/\(id).jsonl")
        try fixture.modified(sessionTestNow.addingTimeInterval(working ? -475 * 60 : -16 * 60), file)
    }
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness())
    let raw = await provider.currentSessions(now: sessionTestNow)
    #expect(raw.count == 60)
    #expect(raw.allSatisfy { $0.isAlive == true })
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    await service.setActiveWindow(900)
    await service.refreshNow()
    let shown = await service.latestUpdate()?.sessions ?? []
    #expect(shown.count == 5)
    #expect(shown.allSatisfy { $0.phase == .thinking })
    #expect(Set(shown.map(\.sessionId)) == Set((55..<60).map { "fixture-\($0)" }))
    await service.stop()
}

@Test func codexDiscoversOldFallbackWorkingTurnsButHidesStaleRecords() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let old = sessionTestNow.addingTimeInterval(-7 * 86400)
    for (index, phase) in [SessionPhase.thinking, .runningTool, .waitingInput].enumerated() {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        var text = try codexLine("event_msg", ["type": "task_started", "turn_id": "fixture"], date: old)
        if phase == .runningTool {
            text += try codexLine("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "command": "fixture-tool"]], date: old)
        } else if phase == .waitingInput {
            text += try codexLine("event_msg", ["type": "task_complete", "turn_id": "fixture"], date: old)
        }
        let file = try fixture.write(text, fixture.rolloutPath(id: id, date: old))
        try fixture.modified(old, file)
    }
    let provider = CodexSessionProvider(paths: fixture.paths)
    let raw = await provider.currentSessions(now: sessionTestNow)
    #expect(raw.count == 3)
    #expect(Set(raw.map(\.phase)) == [.thinking, .runningTool, .waitingInput])
    let shown = SessionVisibilityPolicy.shownSessions(raw, now: sessionTestNow, activeWindow: 900)
    #expect(shown.isEmpty)
    let decisions = SessionVisibilityPolicy.decisions(for: raw, now: sessionTestNow, activeWindow: 900)
    #expect(raw.filter { $0.phase.isWorking }.allSatisfy { decisions[$0.id]?.reason == .staleWorking })
}

@Test func codexAbandonedRolloutBatchEndingInToolCallsIsHiddenAfterDaysWithoutActivity() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    for index in 0..<55 {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        let old = sessionTestNow.addingTimeInterval(-Double(2 + index % 35) * 86400)
        let text = try codexLine("event_msg", ["type": "task_started", "turn_id": "fixture"], date: old)
            + codexLine("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "command": "fixture-tool"]], date: old)
        let file = try fixture.write(text, fixture.rolloutPath(id: id, date: old))
        try fixture.modified(old, file)
    }
    let provider = CodexSessionProvider(paths: fixture.paths)
    let raw = await provider.currentSessions(now: sessionTestNow)
    #expect(raw.count == 55)
    #expect(raw.allSatisfy { $0.phase == .runningTool && $0.isAlive == nil })
    #expect(raw.allSatisfy { sessionTestNow.timeIntervalSince($0.lastActivityAt) >= 2 * 86400 })
    let decisions = SessionVisibilityPolicy.decisions(for: raw, now: sessionTestNow, activeWindow: 900)
    #expect(decisions.count == 55)
    #expect(decisions.values.allSatisfy { !$0.shown && $0.reason == .staleWorking })
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    await service.setActiveWindow(900)
    await service.start()
    #expect(await service.latestUpdate()?.sessions.isEmpty == true)
    #expect(await service.nextExpirationAt == nil)
    await service.stop()
}

@MainActor @Test(arguments: [SessionPhase.waitingInput, .runningTool, .waitingPermission])
func expiredSessionsUpdateStoreColumnsLayoutWingsAndWorkingState(phase: SessionPhase) async {
    let scheduler = ManualSessionScheduler()
    let age: TimeInterval = phase == .waitingInput ? 899 : 7199
    let claude = WindowProvider(values: (0..<3).map { windowSession(phase, id: "claude-\($0)", age: age, alive: nil) })
    let codex = WindowProvider(.codex, values: (0..<3).map { windowSession(phase, agent: .codex, id: "codex-\($0)", age: age, alive: nil) })
    let service = SessionService(providers: [claude, codex], clock: wallClock(scheduler), scheduler: scheduler)
    let store = IslandStore()
    // Session counts in the collapsed wings are used by providers with no quota backend.
    store.providerDetection.claudeCredentialsPresent = false
    store.latestClaudeModel = "glm-fixture"
    let notch = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTop: 32, auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 667, height: 32),
        auxiliaryTopRight: CGRect(x: 845, y: 950, width: 667, height: 32))
    await service.setActiveWindow(900)
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    store.sessions = await iterator.next()?.sessions ?? []
    #expect(store.displaySessionColumns.map(\.count) == [3, 3])
    #expect(store.sessionLayout(notch: notch).columns == 2)
    #expect(store.providerWings.left == .sessions(.claude, count: 3))
    #expect(store.anyWorking == phase.isWorking)
    scheduler.advance(by: .milliseconds(1002))
    store.sessions = await iterator.next()?.sessions ?? []
    #expect(store.displaySessionColumns.map(\.count) == [0, 0])
    #expect(store.sessionLayout(notch: notch).columns == 1)
    #expect(store.providerWings.left == .sessions(.claude, count: 0))
    #expect(store.workingSessions(for: .claude).isEmpty && store.workingSessions(for: .codex).isEmpty)
    #expect(!store.anyWorking)
    await service.stop()
}
