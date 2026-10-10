import Foundation
import Testing
import IslandCore
@testable import AgentIsland

@MainActor @Test(arguments: [1, 2])
func dumpRetainsAllSessionsWithFlattenedVisibilityAndReasons(columns: Int) throws {
    let input = SnapshotExporter.sessionWindowFixtures(includeWorking: true)
    let now = SnapshotExporter.now.addingTimeInterval(120)
    let payload = DumpSessions.displayPayload(input, columns: columns, now: now, activeWindow: 900)
    let data = try JSONEncoder().encode(payload)
    let object = try JSONSerialization.jsonObject(with: data)
    let entries: [[String: Any]]
    if columns == 1 { entries = try #require(object as? [[String: Any]]) }
    else {
        let groups = try #require(object as? [String: [[String: Any]]])
        entries = (groups["claude"] ?? []) + (groups["codex"] ?? [])
    }
    #expect(entries.count == 10)
    let shown = Set(entries.filter { $0["shown"] as? Bool == true }.compactMap { $0["id"] as? String })
    #expect(shown == Set(SessionVisibilityPolicy.shownSessions(input, now: now, activeWindow: 900).map(\.id)))
    for entry in entries {
        let phase = try #require(entry["phase"] as? String)
        #expect(entry["session"] == nil)
        if entry["agent"] as? String == "claude" { #expect(entry["isAlive"] as? Bool == true) }
        else { #expect(entry["isAlive"] == nil) }
        if phase == "waitingInput" {
            #expect(entry["shown"] as? Bool == false)
            #expect(entry["reason"] as? String == "idleExpired")
        } else {
            #expect(entry["shown"] as? Bool == true)
            #expect(entry["reason"] as? String == (phase == "waitingPermission" ? "waitingPermission" : "working"))
        }
    }
}

@MainActor private final class FixtureDumpDefaults: SessionDumpDefaults {
    var domains: [String: [String: Any]]
    var reads: [String] = []
    init(_ domains: [String: [String: Any]]) { self.domains = domains }
    func persistentDomain(forName name: String) -> [String: Any]? {
        reads.append(name)
        return domains[name]
    }
}

@MainActor @Test(arguments: [15, 30, 60])
func dumpReadsGUISettingsDomainAndReportsItsActiveWindow(activeMinutes: Int) throws {
    let defaults = FixtureDumpDefaults([
        "org.agentisland.AgentIsland": ["activeMinutes": activeMinutes],
        "AgentIsland": ["activeMinutes": 30]
    ])
    let settings = DumpSessions.settings(defaults: defaults)
    #expect(settings.activeMinutes == activeMinutes)
    #expect(defaults.reads == ["org.agentisland.AgentIsland"])
    let now = SnapshotExporter.now
    let input = [16.0, 27.0].map { minutes in
        AgentSession(agent: .codex, sessionId: "fixture-\(minutes)", title: "脱敏会话", phase: .waitingInput,
                     lastActivityAt: now.addingTimeInterval(-minutes * 60))
    }
    let payload = DumpSessions.displayPayload(input, columns: 1, now: now, activeWindow: Double(settings.activeMinutes) * 60)
    let report = DumpSessions(generatedAt: now, activeWindowMinutes: settings.activeMinutes, sessions: payload,
        diagnostics: .init(claude: .init(), codex: .init()), warnings: [:])
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["activeWindowMinutes"] as? Int == activeMinutes)
    let entries = try #require(object["sessions"] as? [[String: Any]])
    #expect(entries.count == 2)
    #expect(entries.allSatisfy { $0["shown"] as? Bool == (activeMinutes >= 30) })
    if activeMinutes == 15 { #expect(entries.allSatisfy { $0["reason"] as? String == "idleExpired" }) }
    #expect(defaults.domains["org.agentisland.AgentIsland"]?["activeMinutes"] as? Int == activeMinutes)
}

@MainActor @Test func dumpFallsBackOnlyWhenGUIActiveWindowSettingIsMissingOrInvalid() {
    for domain in [[:], ["activeMinutes": "invalid"], ["activeMinutes": 16]] as [[String: Any]] {
        let defaults = FixtureDumpDefaults(["org.agentisland.AgentIsland": domain, "AgentIsland": ["activeMinutes": 15]])
        #expect(DumpSessions.settings(defaults: defaults).activeMinutes == 30)
    }
    let missing = FixtureDumpDefaults(["AgentIsland": ["activeMinutes": 15]])
    #expect(DumpSessions.settings(defaults: missing).activeMinutes == 30)
}

@MainActor @Test(arguments: [15, 30, 60])
func dumpDiagnosticHomeUsesInjectedUserWindowWhenCollectingRollouts(activeMinutes: Int) async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    for (index, minutes) in [16.0, 27.0].enumerated() {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        let old = sessionTestNow.addingTimeInterval(-minutes * 60)
        let text = try codexLine("event_msg", ["type": "task_started", "turn_id": "fixture"], date: old)
            + codexLine("event_msg", ["type": "task_complete", "turn_id": "fixture"], date: old)
        let file = try fixture.write(text, fixture.rolloutPath(id: id, date: old))
        try fixture.modified(old, file)
    }
    let defaults = FixtureDumpDefaults(["org.agentisland.AgentIsland": ["activeMinutes": activeMinutes]])
    let report = await DumpSessions.collect(home: fixture.root, now: sessionTestNow, defaults: defaults)
    #expect(report.activeWindowMinutes == activeMinutes)
    guard case let .merged(entries) = report.sessions else { Issue.record("Diagnostic homes use a merged session array"); return }
    #expect(entries.count == 2)
    #expect(entries.allSatisfy { $0.session.phase == .waitingInput && $0.visibility.shown == (activeMinutes >= 30) })
    let fallback = await DumpSessions.collect(home: fixture.root, now: sessionTestNow, defaults: FixtureDumpDefaults([:]))
    #expect(fallback.activeWindowMinutes == 30)
    guard case let .merged(fallbackEntries) = fallback.sessions else { Issue.record("Expected merged fallback sessions"); return }
    #expect(fallbackEntries.count == 2 && fallbackEntries.allSatisfy { $0.visibility.shown })
}

@MainActor @Test func dumpRetainsStaleWorkingSessionsWithReasonAndUnknownLiveness() throws {
    let input = [90.0, 180.0, 36 * 1440.0].map { minutes in
        AgentSession(agent: .codex, sessionId: "fixture-\(minutes)", title: "脱敏工具会话", phase: .runningTool,
                     lastActivityAt: SnapshotExporter.now.addingTimeInterval(-minutes * 60))
    }
    let data = try JSONEncoder().encode(DumpSessions.displayPayload(input, columns: 1, now: SnapshotExporter.now, activeWindow: 900))
    let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0["isAlive"] == nil && $0["phase"] as? String == "runningTool" })
    #expect(entries.filter { $0["shown"] as? Bool == true }.count == 1)
    #expect(entries.filter { $0["shown"] as? Bool == false && $0["reason"] as? String == "staleWorking" }.count == 2)
}

@MainActor @Test func dumpExplainsDisplayLimitWithoutRemovingRecords() throws {
    let input = (0..<60).map { index in
        AgentSession(agent: .claude, sessionId: "fixture-\(index)", title: "脱敏会话", phase: .waitingInput,
                     lastActivityAt: SnapshotExporter.now.addingTimeInterval(-Double(index)))
    }
    let data = try JSONEncoder().encode(DumpSessions.displayPayload(input, columns: 1, now: SnapshotExporter.now, activeWindow: 900))
    let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(entries.count == 60)
    #expect(entries.filter { $0["shown"] as? Bool == true }.count == 50)
    #expect(entries.filter { $0["reason"] as? String == "sessionLimit" }.count == 10)
}
