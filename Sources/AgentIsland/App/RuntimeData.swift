import Foundation
import IslandCore

@MainActor struct RuntimeData {
    let quota: QuotaService
    let sessions: SessionService
    let store: IslandStore

    init(options: LaunchOptions) {
        if let scenario = options.mockScenario {
            let fixture = IslandStore.mock(scenario)
            quota = QuotaService(providers: AgentKind.allCases.map { agent in
                FixtureQuotaProvider(agent: agent, snapshot: fixture.quotas[agent])
            }, intervals: [.claude: 60, .codex: 60])
            sessions = SessionService(providers: AgentKind.allCases.map { agent in
                FixtureSessionProvider(agent: agent, values: fixture.sessions.filter { $0.agent == agent })
            })
            store = options.measure ? IslandStore(quotaService: quota, sessionService: sessions, processStarted: options.processStarted) : fixture
        } else {
            quota = QuotaService(diagnostics: .shared)
            sessions = SessionService(providers: [ClaudeSessionProvider(), CodexSessionProvider()])
            store = IslandStore(quotaService: quota, sessionService: sessions, processStarted: options.processStarted)
        }
    }
}

private struct FixtureQuotaProvider: QuotaProviding {
    let agent: AgentKind
    let snapshot: QuotaSnapshot?
    func fetchQuota() async throws -> QuotaSnapshot {
        guard var snapshot else { throw QuotaError.notConfigured("请在终端登录") }
        snapshot.fetchedAt = Date()
        return snapshot
    }
}
private struct FixtureSessionProvider: SessionProviding {
    let agent: AgentKind
    let values: [AgentSession]
    func currentSessions(now: Date) async -> [AgentSession] { values }
    func changes() -> AsyncStream<Set<String>> { AsyncStream { _ in } }
}
