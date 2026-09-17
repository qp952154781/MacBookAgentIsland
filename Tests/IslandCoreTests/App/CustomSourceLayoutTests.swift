import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

@MainActor private final class CustomMemoryDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor @Test func customSettingsCRUDOrderPersistenceAndWings() throws {
    let defaults = CustomMemoryDefaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.declarations.map(\.id) == [.claude, .codex])
    var custom = CustomSource(name: "余额", command: "echo 62", colorIndex: 2)
    settings.saveCustomSource(custom)
    #expect(settings.declarations.map(\.id) == [.claude, .codex, custom.id])
    custom.name = "本月余额"; custom.intervalMinutes = 15
    settings.saveCustomSource(custom)
    settings.moveProvider(custom.id, by: -1); settings.moveProvider(custom.id, by: -1)
    settings.setProviderOverride(false, for: .codex)
    let restored = AppSettings(defaults: defaults)
    #expect(restored.customSources == [custom])
    #expect(restored.declarations.map(\.id) == [custom.id, .claude, .codex])
    #expect(restored.providerOverrides[.codex] == false)
    let store = IslandStore.mock(.idle)
    restored.apply(to: store)
    store.quotas[custom.id] = try CustomQuotaParser.parse(Data("62".utf8), source: custom).snapshot
    #expect(store.providerWings.left.agent == custom.id)
    #expect(store.providerWings.right.agent == .claude)
    #expect(store.sessionProviderIDs == [.claude])
    #expect(store.providerStates[0].detected && store.providerStates[0].quotaAvailable)
    #expect(!store.providerStates[0].sessionsAvailable)
    restored.deleteCustomSource(custom.id)
    let deleted = AppSettings(defaults: defaults)
    #expect(deleted.customSources.isEmpty && !deleted.providerOrder.contains(custom.id))
    #expect(deleted.declarations.map(\.id) == [.claude, .codex])
    deleted.apply(to: store)
    #expect(store.quotas[custom.id] == nil)
}

@MainActor @Test func customPeriodOrderingFallbackAndPrimaryValueText() throws {
    let store = IslandStore()
    let custom = CustomSource(name: "余额", command: "echo 62")
    store.customSources = [custom]
    store.providerOverrides = [.claude: false, .codex: false]
    func apply(_ json: String) throws { store.quotas[custom.id] = try CustomQuotaParser.parse(Data(json.utf8), source: custom).snapshot }
    try apply(#"{"windows":[{"label":"余额","valueText":"¥128.50"},{"label":"额度","remainingPercent":70},{"label":"额外","usedPercent":95}]}"#)
    guard case let .quota(_, left, _) = store.providerWings.left, case let .quota(_, right, _) = store.providerWings.right else {
        Issue.record("Expected two windows"); return
    }
    #expect(left?.label == "余额" && right?.label == "额度")
    #expect(QuotaDisplayMode.remaining.percent(left) == "¥128.50")
    #expect(QuotaDisplayMode.used.percent(left) == "¥128.50")
    #expect(store.headline(for: custom.id)?.label == "余额")
    try apply(#"{"windows":[{"label":"长","remainingPercent":70,"periodSeconds":3600},{"label":"短","usedPercent":10,"periodSeconds":10},{"label":"中","remainingPercent":80,"periodSeconds":30}]}"#)
    guard case let .quota(_, shortest, _) = store.providerWings.left, case let .quota(_, longest, _) = store.providerWings.right else {
        Issue.record("Expected timed windows"); return
    }
    #expect(shortest?.label == "短" && longest?.label == "长")
    store.providerOverrides = [:]; store.providerOrder = [custom.id]
    #expect(store.headline(for: custom.id)?.label == "长")
}

@MainActor @Test func customThreeAndFourCardsUseTwoRowsAndHeight() {
    let store = IslandStore.mock(.idle, now: SnapshotExporter.now)
    let notch = SnapshotExporter.metrics(hasNotch: true)
    let oldHeight = ExpandedView.contentHeight(store: store, notch: notch)
    for scenario in ["custom-one", "custom-two"] {
        SnapshotExporter.configureCustomSources(store, scenario: scenario)
        #expect(store.quotaProviderIDs.count == (scenario == "custom-one" ? 3 : 4))
        #expect(ExpandedView.cardRows(store: store) == 2)
        #expect(ExpandedView.contentHeight(store: store, notch: notch) > oldHeight + 130)
        #expect(ExpandedView.overhead(store: store) >= ExpandedView.cardHeight(store: store) * 2 + 12)
    }
    SnapshotExporter.configureCustomSources(store, scenario: "custom-left")
    #expect(store.providerWings.left.agent?.rawValue == "custom-example-balance")
    guard case let .quota(_, window, _) = store.providerWings.left else { Issue.record("Expected balance"); return }
    #expect(QuotaDisplayMode.remaining.percent(window) == "¥128.50")
    SnapshotExporter.configureCustomSources(store, scenario: "custom-error")
    #expect(store.quotaDiagnostics.values.contains("命令超时"))
    #expect(CustomSourceEditor.samplePreview.snapshot.windows.first?.remainingPercent == 62)
}

@MainActor @Test func customOrderIgnoresUnknownAndDuplicateIDs() {
    let settings = AppSettings()
    settings.providerOrder = [.codex, .codex, .init(rawValue: "missing"), .claude]
    #expect(settings.declarations.map(\.id) == [.codex, .claude])
    settings.saveCustomSource(.init(id: .claude, name: "invalid", command: "echo 62"))
    settings.saveCustomSource(.init(name: "", command: "echo 62"))
    #expect(settings.customSources.isEmpty)
}

@MainActor @Test func customValueSnapshotsCoverBothWingsAndLongBalances() {
    for scenario in ["custom-left", "custom-left-wide", "custom-left-hide-icon", "custom-left-truncated", "custom-single-value"] {
        let store = IslandStore.mock(.idle, now: SnapshotExporter.now)
        SnapshotExporter.configureCustomSources(store, scenario: scenario)
        guard case let .quota(_, window, _) = store.providerWings.left else { Issue.record("Expected a balance wing"); continue }
        #expect(window?.valueText != nil)
        #expect(store.wingWidth == (scenario == "custom-left-wide" ? 100 : 60))
        if scenario == "custom-single-value" {
            #expect(store.providerWings.singleProvider)
            guard case let .quota(_, right, _) = store.providerWings.right else { Issue.record("Expected a second balance"); continue }
            #expect(right?.valueText == "¥987654.32")
        }
    }
}
