import Foundation
import Testing
@testable import IslandCore

private actor RescanProvider: SessionProviding {
    nonisolated let agent: AgentKind
    nonisolated let signals = AsyncStream<Set<String>>.makeStream()
    var starts: [ContinuousClock.Instant] = []
    var requests: [Set<String>?] = []
    var warning: String?
    var revision = 0
    let scheduler: ManualSessionScheduler
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    var paused = false
    init(_ agent: AgentKind, scheduler: ManualSessionScheduler) { self.agent = agent; self.scheduler = scheduler }
    nonisolated func changes() -> AsyncStream<Set<String>> { signals.stream }
    func diagnosticMessage() async -> String? { warning }
    func currentSessions(now: Date) async -> [AgentSession] { await currentSessions(now: now, changedPaths: nil) }
    func currentSessions(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        starts.append(scheduler.now()); requests.append(changedPaths)
        if paused {
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        return [AgentSession(agent: agent, sessionId: "fixture", title: "会话 \(revision)", phase: .thinking,
                             lastActivityAt: sessionTestNow)]
    }
    func setWarning(_ value: String) { warning = value }
    func setRevision(_ value: Int) { revision = value }
    func setPaused(_ value: Bool) { paused = value }
}

@Test func providerIsolationAndUnchangedUpdatesIncludeStableWarnings() async {
    let scheduler = ManualSessionScheduler()
    let claude = RescanProvider(.claude, scheduler: scheduler), codex = RescanProvider(.codex, scheduler: scheduler)
    let service = SessionService(providers: [claude, codex], scheduler: scheduler)
    await claude.setWarning("固定诊断")
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    #expect(await iterator.next()?.sessions.count == 2)
    await service.changed(agent: .claude, paths: ["/fixture/one.jsonl"])
    scheduler.advance(by: .milliseconds(500))
    await service.waitForPendingRefresh()
    #expect(await claude.starts.count == 2)
    #expect(await codex.starts.count == 1)
    #expect(await service.metrics.updatesPublished == 1)
    await claude.setWarning("新的诊断")
    await service.changed(agent: .claude, paths: ["/fixture/two.jsonl"])
    scheduler.advance(by: .milliseconds(500))
    await service.waitForPendingRefresh()
    #expect(await service.metrics.updatesPublished == 2)
    #expect(await codex.starts.count == 1)
    await service.stop()
    #expect(await iterator.next()?.warnings[.claude] == "新的诊断")
    #expect(await iterator.next() == nil)
}

@Test func sustainedSignalsRespectPerProviderSpacingAndRetainEveryPath() async {
    let scheduler = ManualSessionScheduler()
    let claude = RescanProvider(.claude, scheduler: scheduler), codex = RescanProvider(.codex, scheduler: scheduler)
    let service = SessionService(providers: [claude, codex], scheduler: scheduler)
    await service.start()
    var expected: Set<String> = []
    for batch in 0..<3 {
        let deadline = scheduler.now().advanced(by: .milliseconds(500))
        for index in 0..<10 {
            let path = "/fixture/\(batch * 10 + index).jsonl"
            expected.insert(path)
            await service.changed(agent: .claude, paths: [path])
            await service.changed(agent: .codex, paths: [path])
            scheduler.advance(by: .milliseconds(40))
        }
        await scheduler.waitForSleep(until: deadline)
        scheduler.advance(by: .milliseconds(99))
        #expect(await claude.starts.count == batch + 1)
        #expect(await codex.starts.count == batch + 1)
        scheduler.advance(by: .milliseconds(1))
        await service.waitForPendingRefresh()
    }
    for provider in [claude, codex] {
        let starts = await provider.starts
        #expect(starts.count == 4)
        for (a, b) in zip(starts, starts.dropFirst()) { #expect(a.duration(to: b) == .milliseconds(500)) }
        let paths = await provider.requests.compactMap { $0 }.reduce(into: Set<String>()) { $0.formUnion($1) }
        #expect(paths == expected)
    }
    #expect(await service.metrics.sessionRescansSkipped == 60)
    await service.stop()
}

@Test func pathsArrivingDuringScanAreProcessedOnNextScan() async {
    let scheduler = ManualSessionScheduler()
    let provider = RescanProvider(.claude, scheduler: scheduler)
    let service = SessionService(providers: [provider], scheduler: scheduler)
    await service.start()
    await provider.setPaused(true)
    await service.changed(agent: .claude, paths: ["/fixture/first.jsonl"])
    scheduler.advance(by: .milliseconds(500))
    for await _ in provider.entered.stream { break }
    await service.changed(agent: .claude, paths: ["/fixture/second.jsonl"])
    scheduler.advance(by: .milliseconds(350))
    await provider.setPaused(false)
    provider.release.continuation.yield(())
    let deadline = scheduler.now().advanced(by: .milliseconds(500))
    await scheduler.waitForSleep(until: deadline)
    scheduler.advance(by: .milliseconds(499))
    #expect(await provider.starts.count == 2)
    scheduler.advance(by: .milliseconds(1))
    await service.waitForPendingRefresh()
    #expect(await provider.requests.compactMap { $0 } == [["/fixture/first.jsonl"], ["/fixture/second.jsonl"]])
    let starts = await provider.starts
    #expect(starts[1].duration(to: starts[2]) == .milliseconds(850))
    await service.stop()
}

@Test func hiddenScansWaitThirtySecondsAndWakeRefreshesImmediately() async {
    let scheduler = ManualSessionScheduler()
    let provider = RescanProvider(.claude, scheduler: scheduler)
    let service = SessionService(providers: [provider], scheduler: scheduler)
    var iterator = await service.updates().makeAsyncIterator()
    await service.start()
    _ = await iterator.next()
    let hidden = scheduler.now()
    await scheduler.waitForSleep(until: hidden.advanced(by: .seconds(30)))
    await provider.setRevision(1)
    await service.setVisible(false)
    for index in 0..<20 { await service.changed(agent: .claude, paths: ["/fixture/\(index).jsonl"]) }
    await scheduler.waitForSleep(until: hidden.advanced(by: .seconds(30)))
    scheduler.advance(by: .milliseconds(29_999))
    #expect(await provider.starts.count == 1)
    scheduler.advance(by: .milliseconds(1))
    await scheduler.waitForSleep(until: hidden.advanced(by: .seconds(60)))
    #expect(await iterator.next()?.sessions.first?.title == "会话 1")
    #expect(await provider.starts == [hidden, hidden.advanced(by: .seconds(30))])
    await provider.setRevision(2)
    let waking = scheduler.now()
    await service.setVisible(true)
    await service.waitForPendingRefresh()
    #expect(await iterator.next()?.sessions.first?.title == "会话 2")
    #expect(await provider.starts.count == 3)
    #expect(await provider.starts.last == waking)
    await service.stop()
}

@Test func initiallyHiddenServiceCanWakeWithoutWaitingForInitialScan() async {
    let scheduler = ManualSessionScheduler()
    let provider = RescanProvider(.claude, scheduler: scheduler)
    let service = SessionService(providers: [provider], scheduler: scheduler)
    await service.setVisible(false)
    let starting = Task { await service.start() }
    await scheduler.waitForSleep(until: scheduler.now().advanced(by: .seconds(30)))
    #expect(await provider.starts.isEmpty)
    await service.setVisible(true)
    await starting.value
    #expect(await provider.starts == [scheduler.now()])
    await service.stop()
}

@Test func fileSelectionRetainsUntouchedLogsAndReconcilesMissedAppends() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let first = "12345678-1234-1234-1234-123456789011"
    let second = "12345678-1234-1234-1234-123456789012"
    let initial = try codexLine("event_msg", ["type": "task_started", "turn_id": "one"])
    let a = try fixture.write(initial, fixture.rolloutPath(id: first, date: sessionTestNow))
    let b = try fixture.write(initial, fixture.rolloutPath(id: second, date: sessionTestNow))
    for url in [a, b] { try fixture.modified(sessionTestNow, url) }
    let provider = CodexSessionProvider(paths: fixture.paths)
    #expect(await provider.currentSessions(now: sessionTestNow).count == 2)
    let complete = try codexLine("event_msg", ["type": "task_complete", "turn_id": "one"])
    for url in [a, b] { try fixture.append(complete, to: url); try fixture.modified(sessionTestNow, url) }
    let selected = await provider.currentSessions(now: sessionTestNow, changedPaths: [a.path])
    #expect(selected.first { $0.sessionId == first }?.phase == .waitingInput)
    #expect(selected.first { $0.sessionId == second }?.phase == .thinking)
    #expect(await provider.diagnostics.parsedBytes == complete.utf8.count)
    let reconciled = await provider.currentSessions(now: sessionTestNow)
    #expect(reconciled.allSatisfy { $0.phase == .waitingInput })
    #expect(await provider.diagnostics.parsedBytes == complete.utf8.count)
    _ = await provider.currentSessions(now: sessionTestNow)
    #expect(await provider.diagnostics.parsedBytes == 0)
}

@Test func claudeSelectiveFilesDiscoveryDeletionAndMetadata() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let initial = try claudeLine("user", message: ["content": "开始"])
    let a = try fixture.write(initial, ".claude/projects/project/a.jsonl")
    let b = try fixture.write(initial, ".claude/projects/project/b.jsonl")
    for url in [a, b] { try fixture.modified(sessionTestNow, url) }
    for id in ["a", "b"] {
        try fixture.write("{\"pid\":123,\"sessionId\":\"\(id)\"}", ".claude/sessions/\(id).json")
    }
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness())
    #expect(await provider.currentSessions(now: sessionTestNow).count == 2)
    let complete = try claudeLine("assistant", message: ["stop_reason": "end_turn"])
    for url in [a, b] { try fixture.append(complete, to: url); try fixture.modified(sessionTestNow, url) }
    let selected = await provider.currentSessions(now: sessionTestNow, changedPaths: [a.path])
    #expect(selected.first { $0.sessionId == "a" }?.phase == .waitingInput)
    #expect(selected.first { $0.sessionId == "b" }?.phase == .thinking)
    #expect(await provider.diagnostics.parsedBytes == complete.utf8.count)
    let metadata = try fixture.write("{\"cliSessionId\":\"a\",\"title\":\"新标题\"}",
                                    "Library/Application Support/Claude/claude-code-sessions/u/p/local_a.json")
    let titled = await provider.currentSessions(now: sessionTestNow, changedPaths: [metadata.path])
    #expect(titled.first { $0.sessionId == "a" }?.title == "新标题")
    #expect(await provider.diagnostics.parsedBytes == 0)
    try FileManager.default.removeItem(at: b)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".claude/sessions/b.json"))
    let removed = await provider.currentSessions(now: sessionTestNow, changedPaths: [b.path, fixture.paths.claude.appendingPathComponent("sessions").path])
    #expect(removed.count == 1)
    let c = try fixture.write(initial, ".claude/projects/project/c.jsonl")
    try fixture.modified(sessionTestNow, c)
    #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [c.path]).count == 2)
}

@Test func logStampSkipsReadsAndRecoversSameSizeRewritePartialLineAndRotation() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let first = try codexLine("event_msg", ["type": "task_started", "turn_id": "one"])
    let url = try fixture.write(first, "rollout-fixture.jsonl")
    var log = SessionLog<CodexRollout>(url: url)
    #expect(await log.read(url: url) == first.utf8.count)
    #expect(await log.read(url: url) == 0)
    let rewritten = first.replacingOccurrences(of: "one", with: "two")
    try Data(rewritten.utf8).write(to: url)
    #expect(await log.read(url: url) == rewritten.utf8.count)
    #expect(log.state.turnID == "two")
    let complete = try codexLine("event_msg", ["type": "task_complete", "turn_id": "two"])
    try fixture.append(String(complete.dropLast()), to: url)
    #expect(await log.read(url: url) == complete.utf8.count - 1)
    #expect(log.state.active)
    try fixture.append("\n", to: url)
    #expect(await log.read(url: url) == 1)
    #expect(log.state.completed)
    try Data(first.utf8).write(to: url, options: .atomic)
    _ = await log.read(url: url)
    #expect(log.state.turnID == "one")
    #expect(log.state.active)
}

@Test func codexReplayedTokenCountsKeepRevisionStable() throws {
    let line = try codexLine("event_msg", ["type": "token_count", "info": [:]])
    var first = CodexRollout(), replay = CodexRollout()
    feed(&first, line + line)
    feed(&replay, line + line)
    #expect(first.tokenCountRevision == replay.tokenCountRevision)
    feed(&first, line)
    #expect(first.tokenCountRevision != replay.tokenCountRevision)
}

@Test func serviceParsedByteMetricsAccumulateOnlyNewReads() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let initial = try claudeLine("user", message: ["content": "开始"])
    let url = try fixture.write(initial, ".claude/projects/p/session.jsonl")
    try fixture.modified(sessionTestNow, url)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    await service.refreshNow()
    #expect(await service.metrics.parsedBytesTotal == initial.utf8.count)
    await service.refreshNow()
    #expect(await service.metrics.parsedBytesTotal == initial.utf8.count)
    #expect(await service.metrics.sessionRescans == 2)
    #expect(await service.metrics.updatesPublished == 1)
    await service.stop()
}
