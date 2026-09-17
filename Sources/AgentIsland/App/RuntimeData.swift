import Foundation
import IslandCore

@MainActor struct RuntimeData {
    let quota: QuotaService
    let sessions: SessionService
    let store: IslandStore

    init(options: LaunchOptions) {
        if let scenario = options.mockScenario {
            let fixture = IslandStore.mock(scenario)
            quota = QuotaService(providers: ProviderRegistry.orderedIDs.map { agent in
                FixtureQuotaProvider(agent: agent, snapshot: fixture.quotas[agent])
            }, intervals: [.claude: 60, .codex: 60])
            sessions = SessionService(providers: ProviderRegistry.orderedIDs.map { agent in
                FixtureSessionProvider(agent: agent, values: fixture.sessions.filter { $0.agent == agent })
            })
            store = options.measure ? IslandStore(quotaService: quota, sessionService: sessions, processStarted: options.processStarted) : fixture
            if options.measure { store.providerDetection = fixture.providerDetection }
        } else {
            quota = QuotaService(diagnostics: .shared)
            sessions = SessionService(providers: [ClaudeSessionProvider(
                modelPreferences: ClaudeModelPreferences(defaults: UserDefaults.standard)), CodexSessionProvider()])
            store = IslandStore(providerDetector: ProviderDetector(), quotaService: quota, sessionService: sessions, processStarted: options.processStarted)
        }
    }
}

private struct FixtureQuotaProvider: QuotaProviding {
    let agent: ProviderID
    let snapshot: QuotaSnapshot?
    func fetchQuota() async throws -> QuotaSnapshot {
        guard var snapshot else { throw QuotaError.notConfigured("请在终端登录") }
        snapshot.fetchedAt = Date()
        return snapshot
    }
}
private struct FixtureSessionProvider: SessionProviding {
    let agent: ProviderID
    let values: [AgentSession]
    func currentSessions(now: Date) async -> [AgentSession] { values }
    func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
}
