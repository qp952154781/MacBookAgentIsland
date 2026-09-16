import Foundation

public func detectSessionEvents(old: [AgentSession], new: [AgentSession], now: Date) -> [IslandEvent] {
    guard !old.isEmpty else { return [] }
    var previous: [String: AgentSession] = [:]
    for session in old { previous[session.id] = session }
    return new.compactMap { session in
        guard let before = previous[session.id], before.phase != session.phase else { return nil }
        let kind: IslandEvent.Kind
        let suffix: String
        switch session.phase {
        case .waitingInput where before.phase.isWorking:
            let started = session.turnStartedAt ?? before.turnStartedAt
            kind = .turnCompleted(duration: started.map { max(0, (session.turnEndedAt ?? now).timeIntervalSince($0)) })
            suffix = "本轮完成"
        case .waitingPermission:
            kind = .needsAttention(reason: session.activity ?? "等待授权"); suffix = "等待授权"
        case .error:
            kind = .failed(message: session.activity ?? "出错"); suffix = "出错"
        default: return nil
        }
        return IslandEvent(agent: session.agent, sessionID: session.id, title: session.title + " · " + suffix,
                           detail: session.projectName, kind: kind, date: now)
    }
}

public func detectQuotaEvents(old: QuotaSnapshot?, new: QuotaSnapshot, warning: Double = 70, critical: Double = 90) -> [IslandEvent] {
    guard let old, old.agent == new.agent else { return [] }
    var previous: [String: QuotaWindow] = [:]
    for window in old.windows { previous[window.id] = window }
    return new.windows.flatMap { window -> [IslandEvent] in
        guard let before = previous[window.id], before.usedPercent.isFinite, window.usedPercent.isFinite,
              window.usedPercent > before.usedPercent else { return [] }
        return [warning, critical].compactMap { threshold in
            guard before.usedPercent < threshold, window.usedPercent >= threshold else { return nil }
            return IslandEvent(agent: new.agent, title: "\(new.agent.displayName) \(window.label)额度已用 \(Int(threshold))%",
                               kind: .quotaThreshold(windowID: window.id, percent: threshold), date: new.fetchedAt)
        }
    }
}

public struct EventDeduper: Sendable {
    private struct Key: Hashable, Sendable {
        var agent: AgentKind
        var session: String?
        var kind: String
    }
    private var lastEmitted: [Key: Date] = [:]
    public init() {}

    public mutating func filter(_ events: [IslandEvent], now: Date) -> [IslandEvent] {
        lastEmitted = lastEmitted.filter { now.timeIntervalSince($0.value) < 30 }
        return events.filter { event in
            let kind: String
            switch event.kind {
            case .turnCompleted: kind = "completed"
            case .needsAttention: kind = "attention"
            case .failed: kind = "failed"
            case let .quotaThreshold(windowID, percent): kind = "quota:\(windowID):\(percent)"
            }
            let key = Key(agent: event.agent, session: event.sessionID, kind: kind)
            guard lastEmitted[key] == nil else { return false }
            lastEmitted[key] = now
            return true
        }
    }
}
