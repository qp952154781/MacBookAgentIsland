import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

@MainActor private final class ModelDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    var writes = 0
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value; writes += 1 }
}

private func modelLine(_ name: String) throws -> String {
    try claudeLine("assistant", message: ["model": name, "content": [], "stop_reason": "end_turn"])
}

private func modelState(_ model: String?, credentials: Bool? = false) throws -> ProviderState {
    try #require(ProviderAvailability.resolve(
        detection: .init(installed: [.claude: true], claudeCredentialsPresent: credentials),
        latestClaudeModel: model).first { $0.id == .claude })
}

@MainActor @Test func claudeModelSurvivesActiveWindowAndRestartWithoutSessionMetadataPersistence() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let defaults = ModelDefaults()
    let text = try claudeLine("custom-title", extra: ["customTitle": "PRIVATE_SESSION_TITLE"]) +
        claudeLine("user", message: ["content": "PRIVATE_PROMPT"], extra: ["cwd": "/private-fixture/project"]) + modelLine("glm-4.6")
    let file = try fixture.write(text, ".claude/projects/p/private-session-id.jsonl")
    try fixture.modified(sessionTestNow, file)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []),
        modelPreferences: ClaudeModelPreferences(defaults: defaults))
    #expect(await provider.currentSessions(now: sessionTestNow).count == 1)
    #expect(try modelState(await provider.latestObservedModel()).thirdPartyBackend)
    #expect(await provider.currentSessions(now: sessionTestNow.addingTimeInterval(46 * 60)).isEmpty)
    #expect(try modelState(await provider.latestObservedModel()).thirdPartyBackend)
    #expect(await provider.diagnostics.parsedBytes == 0)
    #expect(defaults.values as? [String: String] == [ClaudeModelPreferences.key: "glm-4.6"])
    #expect(defaults.writes == 1)

    // No transcript is available after restart: only the App's model preference remains.
    try FileManager.default.removeItem(at: file)
    let restarted = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []),
        modelPreferences: ClaudeModelPreferences(defaults: defaults))
    #expect(await restarted.currentSessions(now: sessionTestNow.addingTimeInterval(46 * 60)).isEmpty)
    #expect(try modelState(await restarted.latestObservedModel()).thirdPartyBackend)
    #expect(defaults.writes == 1)
}

@MainActor @Test func claudeModelBootstrapReadsOnlyNewestModifiedTranscriptTail() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let defaults = ModelDefaults()
    // The name and assistant timestamp deliberately disagree with file modification order.
    let older = try fixture.write(try modelLine("claude-older"), ".claude/projects/z/z.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-3600), older)
    let text = try modelLine("claude-head-must-not-be-read") + String(repeating: "x", count: 2_000_000) + "\n" + modelLine("kimi-fixture")
    let newest = try fixture.write(text, ".claude/projects/a/a.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-46 * 60), newest)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []),
        modelPreferences: ClaudeModelPreferences(defaults: defaults))
    #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    #expect(await provider.latestObservedModel() == "kimi-fixture")
    #expect(await provider.diagnostics.parsedBytes == 1_048_576)
    #expect(defaults.values as? [String: String] == [ClaudeModelPreferences.key: "kimi-fixture"])
    _ = await provider.currentSessions(now: sessionTestNow)
    #expect(await provider.diagnostics.parsedBytes == 0)
}

@MainActor @Test func persistedClaudeModelSkipsInactiveTranscriptBootstrap() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let defaults = ModelDefaults()
    defaults.values[ClaudeModelPreferences.key] = "deepseek-fixture"
    let file = try fixture.write(try modelLine("claude-old"), ".claude/projects/p/old.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-46 * 60), file)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []),
        modelPreferences: ClaudeModelPreferences(defaults: defaults))
    #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    #expect(await provider.latestObservedModel() == "deepseek-fixture")
    #expect(await provider.diagnostics.parsedBytes == 0)
    #expect(defaults.writes == 0)
}

@Test func claudeModelBootstrapDoesNotSearchOlderFilesWhenNewestHasNoModel() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let old = try fixture.write(try modelLine("glm-older"), ".claude/projects/p/old.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-3600), old)
    let text = try claudeLine("user", message: ["model": "glm-not-an-assistant", "content": "fixture"])
    let newest = try fixture.write(text, ".claude/projects/p/new.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-46 * 60), newest)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    #expect(await provider.latestObservedModel() == nil)
    #expect(await provider.diagnostics.parsedBytes == text.utf8.count)
    _ = await provider.currentSessions(now: sessionTestNow)
    #expect(await provider.diagnostics.parsedBytes == 0)
}

@Test(arguments: [29, 31]) func claudeModelBootstrapRespectsThirtyDayLimit(days: Int) async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let text = try modelLine("glm-fixture")
    let file = try fixture.write(text, ".claude/projects/p/old.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-Double(days) * 86400), file)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    #expect(await provider.latestObservedModel() == (days < 30 ? "glm-fixture" : nil))
    #expect(await provider.diagnostics.parsedBytes == (days < 30 ? text.utf8.count : 0))
}

@MainActor @Test func currentClaudeAssistantModelOverridesHistoryAndSwitchesBackToAnthropic() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let defaults = ModelDefaults()
    defaults.values[ClaudeModelPreferences.key] = "claude-before-install"
    let file = try fixture.write(try modelLine("glm-4.6"), ".claude/projects/p/current.jsonl")
    try fixture.modified(sessionTestNow, file)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []),
        modelPreferences: ClaudeModelPreferences(defaults: defaults))
    _ = await provider.currentSessions(now: sessionTestNow)
    #expect(try modelState(await provider.latestObservedModel()).thirdPartyBackend)
    try fixture.append(try modelLine("claude-sonnet-fixture"), to: file)
    try fixture.modified(sessionTestNow.addingTimeInterval(1), file)
    _ = await provider.currentSessions(now: sessionTestNow.addingTimeInterval(1), changedPaths: [file.path])
    #expect(await provider.latestObservedModel() == "claude-sonnet-fixture")
    #expect(try !modelState(await provider.latestObservedModel()).thirdPartyBackend)
    let ignored = try claudeLine("assistant", message: ["model": "glm-sidechain"], extra: ["isSidechain": true]) +
        claudeLine("user", message: ["model": "glm-user", "content": "PRIVATE_PROMPT"]) + claudeLine("assistant")
    try fixture.append(ignored, to: file)
    try fixture.modified(sessionTestNow.addingTimeInterval(2), file)
    _ = await provider.currentSessions(now: sessionTestNow.addingTimeInterval(2), changedPaths: [file.path])
    #expect(defaults.values as? [String: String] == [ClaudeModelPreferences.key: "claude-sonnet-fixture"])
    #expect(defaults.writes == 2)
}

@Test func inactiveClaudeModelReachesSessionServiceAndCredentialsClearBackendClassification() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let file = try fixture.write(try modelLine("glm-4.6"), ".claude/projects/p/old.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-46 * 60), file)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    let service = SessionService(providers: [provider], clock: { sessionTestNow })
    await service.refreshNow()
    let update = try #require(await service.latestUpdate())
    #expect(update.sessions.isEmpty)
    #expect(update.latestClaudeModel == "glm-4.6")
    let detector = ProviderDetector(home: fixture.root, diagnosticHome: true)
    let before = await detector.detect()
    #expect(try modelState(update.latestClaudeModel, credentials: before.claudeCredentialsPresent).thirdPartyBackend)
    try fixture.write("synthetic-presence-only", ".claude/.credentials.json")
    let after = await detector.detect()
    #expect(after.claudeCredentialsPresent == true)
    #expect(try !modelState(update.latestClaudeModel, credentials: after.claudeCredentialsPresent).thirdPartyBackend)
    #expect(try modelState(update.latestClaudeModel, credentials: after.claudeCredentialsPresent).quotaAvailable)
    #expect(try !modelState(update.latestClaudeModel, credentials: nil).thirdPartyBackend)
    await service.stop()
}

@MainActor @Test func dumpProvidersHomeRemembersFortySixMinuteOldModelAcrossRuns() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let text = try claudeLine("custom-title", extra: ["customTitle": "PRIVATE_TITLE"]) + modelLine("glm-4.6")
    let file = try fixture.write(text, ".claude/projects/p/private-id.jsonl")
    try fixture.modified(Date().addingTimeInterval(-46 * 60), file)
    #expect(await DumpProviders.states(home: fixture.root).first { $0.id == .claude }?.thirdPartyBackend == true)
    let preference = fixture.root.appendingPathComponent("Library/Preferences/org.agentisland.AgentIsland.model-history.plist")
    let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: preference), format: nil) as? [String: String]
    #expect(values == [ClaudeModelPreferences.key: "glm-4.6"])
    #expect(try String(contentsOf: file, encoding: .utf8) == text)
    try fixture.modified(Date().addingTimeInterval(-100 * 86400), file)
    #expect(await DumpProviders.states(home: fixture.root).first { $0.id == .claude }?.thirdPartyBackend == true)
    try fixture.append(try modelLine("claude-fixture"), to: file)
    #expect(await DumpProviders.states(home: fixture.root).first { $0.id == .claude }?.thirdPartyBackend == false)
    // A second home has no access to the first home's remembered model.
    let empty = try SessionFixture(); defer { empty.remove() }
    try FileManager.default.createDirectory(at: empty.root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    #expect(await DumpProviders.states(home: empty.root).first { $0.id == .claude }?.thirdPartyBackend == false)
}

private actor ModelOnlyProvider: SessionProviding {
    nonisolated let agent: ProviderID = .claude
    private var model = "glm-fixture"
    func currentSessions(now: Date) -> [AgentSession] { [] }
    func latestObservedModel() async -> String? { model }
    func setModel(_ value: String) { model = value }
    nonisolated func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
}

@Test func sessionServicePublishesModelOnlyChangesWithoutActiveSessions() async throws {
    let provider = ModelOnlyProvider(), scheduler = ManualSessionScheduler()
    let service = SessionService(providers: [provider], clock: { sessionTestNow }, scheduler: scheduler)
    await service.refreshNow()
    #expect(await service.latestUpdate()?.latestClaudeModel == "glm-fixture")
    #expect(await service.metrics.updatesPublished == 1)
    await provider.setModel("claude-fixture")
    scheduler.advance(by: .seconds(1))
    await service.refreshNow()
    #expect(await service.latestUpdate()?.sessions.isEmpty == true)
    #expect(await service.latestUpdate()?.latestClaudeModel == "claude-fixture")
    #expect(await service.metrics.updatesPublished == 2)
    scheduler.advance(by: .seconds(1))
    await service.refreshNow()
    #expect(await service.metrics.updatesPublished == 2)
    await service.stop()
}
