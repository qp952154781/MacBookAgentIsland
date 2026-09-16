import Foundation

/// Display-only ordering. Providers must keep their activity-based retention order.
public enum SessionDisplayOrder {
    /// Sort each provider independently: another provider must not affect project recency.
    public static func columns(_ sessions: [AgentSession]) -> [[AgentSession]] {
        [AgentKind.claude, .codex].map { agent in sorted(sessions.filter { $0.agent == agent }) }
    }

    public static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        let priorities = Dictionary(grouping: sessions) { priority($0.phase) }
        return priorities.keys.sorted().flatMap { priority in
            let projects = Dictionary(grouping: priorities[priority] ?? [], by: \.projectName)
            let groups = projects.map { (project: $0.key, sessions: $0.value.sorted(by: recentFirst)) }
            return groups.sorted { lhs, rhs in
                if lhs.project == nil { return false }
                if rhs.project == nil { return true }
                let left = lhs.sessions.first?.lastActivityAt ?? .distantPast
                let right = rhs.sessions.first?.lastActivityAt ?? .distantPast
                if left != right { return left > right }
                // Equal project timestamps use a locale-independent, deterministic tie-break.
                return (lhs.project ?? "") < (rhs.project ?? "")
            }.flatMap(\.sessions)
        }
    }

    private static func recentFirst(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        lhs.lastActivityAt == rhs.lastActivityAt ? lhs.id < rhs.id : lhs.lastActivityAt > rhs.lastActivityAt
    }

    private static func priority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .runningTool: 1
        case .thinking, .compacting, .retrying: 2
        case .waitingPermission: 3
        case .waitingInput: 4
        case .error: 5
        case .idle: 6
        case .ended: 7
        }
    }
}
