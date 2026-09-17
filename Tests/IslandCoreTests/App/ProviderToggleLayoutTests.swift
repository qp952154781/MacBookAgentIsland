import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

@MainActor @Test func collapsedProviderLayoutsSelectPeriodsAndSystemFallbacks() throws {
    let store = IslandStore.mock(.busy, now: SnapshotExporter.now)
    let original = store.providerWings
    guard case let .quota(left, short, period) = original.left,
          case let .quota(right, weekly, rightPeriod) = original.right else { Issue.record("Expected original two wings"); return }
    #expect(left == .claude && short?.kind == .session && period == nil)
    #expect(right == .codex && weekly?.kind == .weekly && rightPeriod == nil)
    store.providerOverrides = [.codex: false]
    guard case let .quota(_, first, firstPeriod) = store.providerWings.left,
          case let .quota(_, last, lastPeriod) = store.providerWings.right else { Issue.record("Expected two periods"); return }
    #expect(first?.id == "five_hour" && firstPeriod == "5h")
    #expect(last?.id == "seven_day" && lastPeriod == "7d")
    #expect(store.providerWings.singleProvider)
    #expect(!store.collapsedMetricOptions.enabled)
    store.quotas[.claude]?.windows.append(.init(id: "extra_usage", kind: .other, label: "额度包", usedPercent: 12))
    store.quotas[.claude]?.windows.reverse()
    #expect(store.providerWings.right == .quota(.claude, last, period: "7d"))
    store.providerOverrides = [.claude: false]
    #expect(store.providerWings.right == .cpu)
    #expect(store.collapsedMetricOptions.cpu && !store.collapsedMetricOptions.memory)
    guard case let .quota(id, window, label) = store.providerWings.left else { Issue.record("Expected weekly and CPU"); return }
    #expect(id == .codex && window?.kind == .weekly && label == "7d")
    store.providerOverrides = [.codex: false]
    store.providerDetection.claudeCredentialsPresent = false
    store.latestClaudeModel = "glm-fixture"
    #expect(store.providerWings.left == .sessions(.claude, count: 2))
    #expect(store.providerWings.right == .cpu)
    #expect(store.quotaProviderIDs.isEmpty)
    store.providerOverrides = [.claude: false, .codex: false]
    #expect(store.providerWings.left == .cpu && store.providerWings.right == .memory)
    #expect(store.collapsedMetricOptions.cpu && store.collapsedMetricOptions.memory)
    store.systemMetricOptions = .init(network: false, fan: false, memory: false, cpu: false, gpu: false)
    #expect(store.expandedMetricOptions.cpu && store.expandedMetricOptions.memory)
}

@MainActor @Test func singleProviderUnavailableQuotaKeepsUnconnectedPresentation() {
    let store = IslandStore.mock(.disconnected)
    store.providerDetection = .init(installed: [:], claudeCredentialsPresent: false)
    store.providerOverrides = [.claude: true]
    #expect(store.quotaProviderIDs == [.claude])
    #expect(store.providerWings.left == .quota(.claude, nil, period: nil))
    #expect(store.providerWings.right == .cpu)
}

@MainActor @Test func expandedProviderCountsShrinkWithoutStaleHiddenContent() {
    let store = IslandStore.mock(.idle, now: SnapshotExporter.now)
    let notch = SnapshotExporter.metrics(hasNotch: true)
    store.sessionListLayout = .twoColumns
    #expect(store.quotaProviderIDs.count == 2)
    #expect(store.sessionColumns(count: store.sessionLayout(notch: notch).columns).count == 2)
    let both = ExpandedView.contentHeight(store: store, notch: notch)
    #expect(both == 294)
    store.providerOverrides = [.codex: false]
    #expect(store.quotaProviderIDs.count == 1)
    #expect(store.sessionLayout(notch: notch).columns == 1)
    #expect(store.sessionColumns(count: 1).count == 1)
    #expect(store.layoutConfig(notch: notch).expandedWidth == 600)
    store.providerDetection.claudeCredentialsPresent = false
    store.latestClaudeModel = "glm-fixture"
    // Hidden cached quota and recovery text must contribute zero height.
    var status = ClaudeConnectionStatus(); status.isRecovering = true; store.claudeConnection = status
    #expect(ExpandedView.cardHeight(store: store) == 0)
    let sessionsOnly = ExpandedView.contentHeight(store: store, notch: notch)
    #expect(sessionsOnly == notch.notchRect.height + 118)
    #expect(sessionsOnly < both)
    store.providerOverrides = [.claude: false, .codex: false]
    #expect(store.quotaProviderIDs.isEmpty)
    #expect(store.sessionColumns(count: 1).isEmpty)
    let system = ExpandedView.contentHeight(store: store, notch: notch)
    #expect(system == notch.notchRect.height + 112)
    let size = IslandLayout.size(for: .expanded, notch: notch, config: ExpandedView.layoutConfig(store: store, notch: notch), expandedContentHeight: system)
    #expect(size.height == system && size.height < 200)
}

@MainActor @Test func oneQuotaWithoutSessionCapabilityOmitsSessionHeight() {
    let store = IslandStore.mock(.idle)
    let descriptor = ProviderRegistry.descriptor(for: .codex)
    store.providerDeclarations = [.init(id: descriptor.id, displayName: descriptor.displayName,
        brandColor: descriptor.brandColor, iconSource: descriptor.iconSource, hasQuota: true, hasSessions: false)]
    #expect(store.quotaProviderIDs == [.codex])
    #expect(store.sessionProviderIDs.isEmpty)
    let notch = SnapshotExporter.metrics(hasNotch: false)
    #expect(ExpandedView.contentHeight(store: store, notch: notch) == notch.notchRect.height + 188)
}

@MainActor @Test func snapshotProviderCasesCoverBothGeometriesWithoutHostDetection() {
    for hasNotch in [false, true] {
        let notch = SnapshotExporter.metrics(hasNotch: hasNotch)
        for scenario in SnapshotExporter.providerScenarios {
            let store = IslandStore.mock(.busy, now: SnapshotExporter.now)
            SnapshotExporter.configureProviders(store, scenario: scenario)
            let config = ExpandedView.layoutConfig(store: store, notch: notch)
            let height = ExpandedView.contentHeight(store: store, notch: notch)
            let size = IslandLayout.size(for: .expanded, notch: notch, config: config, expandedContentHeight: height)
            #expect(size.height == height)
            #expect(size.width >= 600)
            if scenario == "both" { #expect(store.providerOverrides.isEmpty && store.quotaProviderIDs.count == 2) }
            if scenario == "third-party" { #expect(store.quotaProviderIDs.isEmpty && store.sessionProviderIDs == [.claude]) }
        }
    }
}

@Test func homeIsDumpOnlyAndHelpExplainsIsolation() throws {
    for target in ["providers", "quota", "sessions", "system", "claude-log"] {
        let options = try LaunchOptions(arguments: ["--home", "/fixture", "--dump", target])
        #expect(options.home?.path == "/fixture" && options.dump == target)
    }
    for args in [["--home", "/fixture"], ["--home", "/fixture", "--mock", "idle"], ["--home", "/fixture", "--snapshot", "/fixture/out"]] {
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions(arguments: args) }
    }
    #expect(try LaunchOptions(arguments: ["--help"]).help)
    #expect(LaunchOptions.helpText.contains("跳过钥匙串"))
    #expect(LaunchOptions.helpText.contains("GUI 模式不接受"))
}

@MainActor @Test func disconnectedAndNoCredentialsMocksKeepDistinctAccountStates() throws {
    let recovering = IslandStore.mock(.disconnected, now: SnapshotExporter.now)
    let needsLogin = IslandStore.mock(.noCredentials, now: SnapshotExporter.now)
    #expect(recovering.providerDetection.claudeCredentialsPresent == true)
    #expect(needsLogin.providerDetection.claudeCredentialsPresent == false)
    for store in [recovering, needsLogin] {
        #expect(store.quotaProviderIDs == [.claude, .codex])
        #expect(store.sessions.isEmpty && store.quotas[.claude] == nil)
        guard case .needsSetup = store.health[.claude] else { Issue.record("Expected setup presentation"); return }
        // A full recovery status would add 36 pt and change the M11a snapshot geometry.
        #expect(store.claudeConnection == nil)
        #expect(ExpandedView.cardHeight(store: store) == 134)
        let notch = SnapshotExporter.metrics(hasNotch: true)
        #expect(ExpandedView.contentHeight(store: store, notch: notch) == 294)
    }
    for scenario in [MockScenario.disconnected, .noCredentials] {
        let runtime = RuntimeData(options: try LaunchOptions(arguments: ["--mock", scenario.rawValue, "--measure"]))
        #expect(runtime.store.providerDetection.claudeCredentialsPresent == (scenario == .disconnected))
    }
    #expect(try LaunchOptions(arguments: ["--mock", "no-credentials"]).mockScenario == .noCredentials)
    #expect(LaunchOptions.helpText.contains(".codex/ 是否存在"))
}
