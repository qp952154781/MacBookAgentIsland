import Foundation

public struct SessionVisibility: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case working, waitingPermission, recentActivity, idleExpired, staleWorking, sessionLimit
    }
    public var shown: Bool
    public var reason: Reason
}

/// Shared by the service's published list and the unfiltered diagnostic dump.
public enum SessionVisibilityPolicy {
    public static func expiration(of session: AgentSession, activeWindow: TimeInterval) -> Date? {
        if session.phase.isWorking || session.phase == .waitingPermission {
            switch session.isAlive {
            case true?: return nil
            case nil: return session.lastActivityAt.addingTimeInterval(max(activeWindow, 2 * 60 * 60))
            case false?: break
            }
        }
        return session.lastActivityAt.addingTimeInterval(activeWindow)
    }

    public static func decisions(for sessions: [AgentSession], now: Date, activeWindow: TimeInterval,
                                 limitPerProvider: Int = 50) -> [String: SessionVisibility] {
        var result: [String: SessionVisibility] = [:]
        var recent: [ProviderID: [AgentSession]] = [:]
        var protectedCounts: [ProviderID: Int] = [:]
        for session in sessions {
            let working = session.phase.isWorking || session.phase == .waitingPermission
            if let expiration = expiration(of: session, activeWindow: activeWindow), now > expiration {
                result[session.id] = SessionVisibility(shown: false,
                    reason: working && session.isAlive == nil ? .staleWorking : .idleExpired)
            } else if working {
                result[session.id] = SessionVisibility(shown: true,
                    reason: session.phase == .waitingPermission ? .waitingPermission : .working)
                protectedCounts[session.agent, default: 0] += 1
            } else {
                recent[session.agent, default: []].append(session)
            }
        }
        for (agent, values) in recent {
            let slots = max(0, limitPerProvider - protectedCounts[agent, default: 0])
            for (index, session) in values.sorted(by: sessionOrder).enumerated() {
                result[session.id] = SessionVisibility(shown: index < slots,
                    reason: index < slots ? .recentActivity : .sessionLimit)
            }
        }
        // Eligible working/permission sessions stay visible even if they exceed the soft limit.
        return result
    }

    public static func shownSessions(_ sessions: [AgentSession], now: Date, activeWindow: TimeInterval) -> [AgentSession] {
        let visibility = decisions(for: sessions, now: now, activeWindow: activeWindow)
        return sessions.filter { visibility[$0.id]?.shown == true }.sorted(by: sessionOrder)
    }
}
