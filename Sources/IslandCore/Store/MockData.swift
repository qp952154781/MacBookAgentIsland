import Foundation

public enum MockScenario: String, Sendable, CaseIterable {
    case busy, idle, critical, disconnected
    case noCredentials = "no-credentials"
}

extension IslandStore {
    public static func mock(_ scenario: MockScenario, now: Date = Date()) -> IslandStore {
        let store = IslandStore()
        store.sessionsLoaded = true
        store.lastRefresh = now.addingTimeInterval(-60)
        store.health = [.claude: .ok, .codex: .ok]
        store.quotas[.claude] = QuotaSnapshot(agent: .claude, plan: "max", windows: [
            QuotaWindow(id: "five_hour", kind: .session, label: "5 小时", usedPercent: scenario == .critical ? 97 : 18,
                        windowMinutes: 300, resetsAt: now.addingTimeInterval(7980)),
            QuotaWindow(id: "seven_day", kind: .weekly, label: "本周", usedPercent: scenario == .critical ? 93 : 62,
                        windowMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400)),
            QuotaWindow(id: "seven_day_opus", kind: .weeklyModel, label: "本周 · Opus", usedPercent: 41,
                        windowMinutes: 10080, resetsAt: now.addingTimeInterval(3 * 86400))
        ], source: .mock, fetchedAt: now.addingTimeInterval(-60))
        store.quotas[.codex] = QuotaSnapshot(agent: .codex, plan: "pro", windows: [
            QuotaWindow(id: "codex.primary", kind: .weekly, label: "本周", usedPercent: scenario == .critical ? 88 : 39,
                        windowMinutes: 10080, resetsAt: now.addingTimeInterval(6 * 86400))
        ], source: .mock, fetchedAt: now.addingTimeInterval(-60))
        if scenario == .busy {
            store.sessions = [
                AgentSession(agent: .claude, sessionId: "mock-island", title: "灵动岛屏幕刘海项目",
                             cwd: "/example/AgentIsland", origin: "claude-desktop", model: "claude-opus-5",
                             phase: .thinking, activity: "Bash · swift build",
                             context: ContextUsage(usedTokens: 335_000, windowTokens: 1_000_000),
                             turnStartedAt: now.addingTimeInterval(-180), toolCallsThisTurn: 8, lastActivityAt: now, isAlive: true),
                AgentSession(agent: .codex, sessionId: "mock-quota", title: "实现额度引擎",
                             cwd: "/example/AgentIsland", origin: "exec", model: "gpt-6",
                             phase: .runningTool, activity: "执行 scripts/test.sh",
                             plan: PlanProgress(completed: 3, total: 7, current: "验证额度解析"),
                             turnStartedAt: now.addingTimeInterval(-720), toolCallsThisTurn: 23, lastActivityAt: now, isAlive: true),
                AgentSession(agent: .claude, sessionId: "mock-test", title: "gpt6测试",
                             cwd: "/example/gpt6", origin: "cli", phase: .waitingInput, activity: "本轮已完成",
                             turnStartedAt: now.addingTimeInterval(-240), turnEndedAt: now.addingTimeInterval(-120),
                             lastActivityAt: now.addingTimeInterval(-120), isAlive: true)
            ]

        }
        if scenario == .disconnected || scenario == .noCredentials {
            // Disconnected models a recoverable connection, not a missing account.
            store.providerDetection.claudeCredentialsPresent = scenario == .disconnected
            store.quotas[.claude] = nil
            store.health[.claude] = .needsSetup(message: "在终端运行一次 claude auth login")
        }
        return store
    }
}
