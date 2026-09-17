import Foundation
import Darwin
import Testing
@testable import IslandCore

/// Real parsers with synthetic change signals: FSEvents is unavailable in the test sandbox.
private struct ReplaySessionProvider: SessionProviding {
    let base: any SessionProviding
    let signals = AsyncStream<Set<String>>.makeStream()
    var agent: ProviderID { base.agent }
    func changes() -> AsyncStream<Set<String>> { signals.stream }
    func currentSessions(now: Date) async -> [AgentSession] { await base.currentSessions(now: now) }
    func currentSessions(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        await base.currentSessions(now: now, changedPaths: changedPaths)
    }
    func diagnosticMessage() async -> String? { await base.diagnosticMessage() }
    func parsedBytesLastScan() async -> Int { await base.parsedBytesLastScan() }
}

private func fixtureCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
        Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

@Test func syntheticDualProviderRescanWorkload() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let claudeInitial = try claudeLine("user", message: ["content": "合成负载"])
    let codexInitial = try codexLine("event_msg", ["type": "task_started", "turn_id": "fixture"])
    var claudeFiles: [URL] = [], codexFiles: [URL] = []
    for index in 0..<50 {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        claudeFiles.append(try fixture.write(claudeInitial, ".claude/projects/project/\(id).jsonl"))
        codexFiles.append(try fixture.write(codexInitial, fixture.rolloutPath(id: id, date: sessionTestNow)))
        try fixture.write("{\"pid\":123,\"sessionId\":\"\(id)\"}", ".claude/sessions/\(id).json")
    }
    for url in claudeFiles + codexFiles { try fixture.modified(sessionTestNow, url) }
    let claude = ReplaySessionProvider(base: ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness()))
    let codex = ReplaySessionProvider(base: CodexSessionProvider(paths: fixture.paths))
    let scheduler = ManualSessionScheduler()
    let service = SessionService(providers: [claude, codex], clock: { sessionTestNow }, scheduler: scheduler)
    await service.start()
    let initialBytes = await service.metrics.parsedBytesTotal
    let a = try #require(claudeFiles.first), b = try #require(codexFiles.first)
    let text = String(repeating: "fixture ", count: 256)
    let claudeAppend = try claudeLine("assistant", message: ["id": "fixture", "content": [["type": "text", "text": text]]])
    let codexAppend = try codexLine("event_msg", ["type": "item_completed", "item": ["type": "reasoning", "text": text]])
    let started = ContinuousClock.now, cpu = fixtureCPUSeconds()
    for index in 0..<80 {
        try fixture.append(claudeAppend, to: a)
        try fixture.append(codexAppend, to: b)
        for url in [a, b] { try fixture.modified(sessionTestNow, url) }
        await service.changed(agent: .claude, paths: [a.path])
        await service.changed(agent: .codex, paths: [b.path])
        scheduler.advance(by: .milliseconds(50))
        if (index + 1).isMultiple(of: 10) { await service.waitForPendingRefresh() }
    }
    await service.waitForPendingRefresh()
    let duration = started.duration(to: .now).components
    let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let cpuPercent = (fixtureCPUSeconds() - cpu) / seconds * 100
    let metrics = await service.metrics
    #expect(metrics.parsedBytesTotal - initialBytes == 80 * (claudeAppend.utf8.count + codexAppend.utf8.count))
    #expect(metrics.sessionRescans == 18)
    #expect(metrics.sessionRescansSkipped >= 100)
    let report: [String: Any] = [
        "fixtureSessionCount": 100, "writers": 2, "appendHzPerWriter": 20,
        "virtualSeconds": 4, "executionSeconds": seconds, "cpuPercentIncludingFixtureWriter": cpuPercent,
        "sessionRescans": metrics.sessionRescans, "sessionRescansSkipped": metrics.sessionRescansSkipped,
        "parsedBytesTotal": metrics.parsedBytesTotal, "incrementalBytes": metrics.parsedBytesTotal - initialBytes
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("Synthetic session rescan workload: " + String(decoding: data, as: UTF8.self))
    await service.stop()
}
