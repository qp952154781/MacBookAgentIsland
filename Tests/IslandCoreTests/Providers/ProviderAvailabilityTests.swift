import Foundation
import Testing
@testable import IslandCore

@Test(arguments: [0, 1, 2, 3]) func providerDetectionUsesOnlySyntheticHome(mask: Int) async throws {
    let home = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    if mask & 1 != 0 { try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true) }
    if mask & 2 != 0 { try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true) }
    let executor = FakeQuotaExecutor([])
    let result = await ProviderDetector(home: home, diagnosticHome: true, executor: executor).detect()
    #expect(result.installed[.claude] == (mask & 1 != 0))
    #expect(result.installed[.codex] == (mask & 2 != 0))
    #expect(result.claudeCredentialsPresent == false)
    #expect(await executor.calls.isEmpty)
}

@Test(arguments: [false, true]) func providerDetectionRequiresCodexDirectoryEvenWithBundledExecutables(diagnosticHome: Bool) async throws {
    let root = try quotaTestDirectory(), actual = root.appendingPathComponent("actual"), alias = root.appendingPathComponent("alias")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: actual.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    for path in [".local/bin/codex", "Applications/ChatGPT.app/Contents/Resources/codex"] {
        let binary = actual.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic executable, must never run".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }
    let executor = FakeQuotaExecutor(Array(repeating: .success(.init(stdout: Data(), exitCode: 44)), count: 4))
    let detector = ProviderDetector(home: alias, diagnosticHome: diagnosticHome, executor: executor)
    #expect(await detector.detect().installed == [.claude: true, .codex: false])
    #expect(SessionPaths(home: alias).home.path == physicalPath(actual.path))
    let codex = actual.appendingPathComponent(".codex")
    try Data().write(to: codex)
    #expect(await detector.detect().installed[.codex] == false)
    try FileManager.default.removeItem(at: codex)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    #expect(await detector.detect().installed == [.claude: true, .codex: true])
    try FileManager.default.removeItem(at: actual.appendingPathComponent(".claude"))
    try Data().write(to: actual.appendingPathComponent(".claude"))
    #expect(await detector.detect().installed[.claude] == false)
}

@Test(arguments: [0, 44, 36]) func credentialPresenceNeverRequestsPassword(status: Int32) async throws {
    let home = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let executor = FakeQuotaExecutor([.success(.init(stdout: Data("attributes only".utf8), exitCode: status))])
    let result = await ClaudeCredentialPresence(home: home, executor: executor).exists()
    #expect(result == (status == 0 ? true : status == 44 ? false : nil))
    #expect(await executor.calls.first?.arguments == ["find-generic-password", "-s", "Claude Code-credentials"])
}

@Test func credentialFilePresenceDoesNotDecodeItsContentsOrQueryKeychain() async throws {
    let home = try quotaTestDirectory(), file = home.appendingPathComponent(".claude/.credentials.json")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Deliberately invalid JSON: the existence probe must not open or decode it.
    try Data("synthetic noncredential".utf8).write(to: file)
    let executor = FakeQuotaExecutor([])
    #expect(await ClaudeCredentialPresence(home: home, executor: executor).exists() == true)
    #expect(await ClaudeCredentialPresence(home: home, useKeychain: false, executor: executor).exists() == true)
    #expect(await executor.calls.isEmpty)
}

@Test(arguments: [false, true], ["claude-sonnet-fixture", "glm-fixture", ""]) func thirdPartyBackendRequiresBothPiecesOfEvidence(present: Bool, model: String) {
    let state = ProviderAvailability.resolve(detection: .init(installed: [.claude: true], claudeCredentialsPresent: present),
        latestClaudeModel: model.isEmpty ? nil : model)[0]
    let thirdParty = !present && model == "glm-fixture"
    #expect(state.thirdPartyBackend == thirdParty)
    #expect(state.quotaAvailable == !thirdParty)
    #expect(state.sessionsAvailable)
    #expect(state.quotaReason == (thirdParty ? .thirdPartyBackend : .available))
    #expect(state.statusLabel == (thirdParty ? "第三方后端 · 仅会话" : "已检测到"))
}

@Test func unknownCredentialPresenceDoesNotInferThirdParty() {
    #expect(!ProviderState.isThirdParty(credentialsPresent: nil, model: "glm-fixture"))
    #expect(!ProviderState.isThirdParty(credentialsPresent: false, model: "  "))
}

@MainActor private final class ProviderDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey name: String) -> String? { values[name] as? String }
    func object(forKey name: String) -> Any? { values[name] }
    func set(_ value: Any?, forKey name: String) { values[name] = value }
}

@MainActor @Test func providerOverridesPersistAndRestoreAutomaticDetection() {
    let defaults = ProviderDefaults(), store = IslandStore()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.providerOverrides.isEmpty)
    settings.apply(to: store)
    store.providerDetection = .init(installed: [:])
    #expect(store.visibleProviderIDs.isEmpty)
    store.providerDetection.installed[.claude] = true
    #expect(store.visibleProviderIDs == [.claude])
    settings.setProviderOverride(false, for: .claude); settings.apply(to: store)
    store.providerDetection.installed[.claude] = false
    store.providerDetection.installed[.claude] = true
    #expect(store.visibleProviderIDs.isEmpty)
    #expect(store.providerStates[0].quotaReason == .disabledByUser)
    #expect(AppSettings(defaults: defaults).providerOverrides[.claude] == false)
    settings.setProviderOverride(nil, for: .claude); settings.apply(to: store)
    #expect(store.visibleProviderIDs == [.claude])
    #expect(AppSettings(defaults: defaults).providerOverrides[.claude] == nil)
    store.providerDetection.installed[.claude] = false
    settings.setProviderOverride(true, for: .claude); settings.apply(to: store)
    #expect(store.visibleProviderIDs == [.claude])
    #expect(store.providerStates[0].quotaReason == .notDetected)
}

@Test func runtimeOrderSupportsFutureDeclarationsWithoutAddingAnIntegration() {
    let custom = ProviderID(rawValue: "fixture")
    let declaration = ProviderDescriptor(id: custom, displayName: "测试", brandColor: .init(red: 1, green: 1, blue: 1),
        iconSource: .none, hasQuota: false, hasSessions: true)
    let states = ProviderAvailability.resolve(declarations: [declaration] + ProviderRegistry.ordered,
        detection: .init(installed: [custom: true, .codex: true]))
    #expect(states.filter(\.hasContent).map(\.id) == [custom, .codex])
    #expect(states[0].quotaReason == .unsupported)
    let encoded = try? JSONEncoder().encode(states)
    let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
    #expect(text.contains("\"override\":null"))
    #expect(!text.contains("claudeCredentialsPresent"))
}
