import Foundation

public struct ProviderWingLayout: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case quota(ProviderID, QuotaWindow?, period: String?)
        case sessions(ProviderID, count: Int)
        case cpu, memory
        public var agent: ProviderID? {
            switch self { case let .quota(id, _, _), let .sessions(id, _): id; default: nil }
        }
    }
    public let left: Content
    public let right: Content
    public let singleProvider: Bool
    public var needsCPU: Bool { left == .cpu || right == .cpu }
    public var needsMemory: Bool { left == .memory || right == .memory }

    public init(providers: [ProviderState], quotas: [ProviderID: QuotaSnapshot], health: [ProviderID: ProviderHealth],
                sessions: [AgentSession], mode: QuotaDisplayMode = .remaining) {
        let content = providers.filter(\.hasContent)
        let quotasFirst = content.filter(\.quotaAvailable)
        let visible = quotasFirst.count >= 2 ? quotasFirst : content
        singleProvider = visible.count == 1
        func windows(_ id: ProviderID) -> [QuotaWindow] {
            switch health[id] {
            case .needsSetup, .failed, .disabled: []
            default: quotas[id]?.windows ?? []
            }
        }
        func count(_ id: ProviderID) -> Int { sessions.filter { $0.agent == id && $0.phase != .ended }.count }
        func primary(_ state: ProviderState) -> Content {
            guard state.quotaAvailable else { return .sessions(state.id, count: count(state.id)) }
            let headline = quotas[state.id].flatMap { mode.headline($0) }
            return .quota(state.id, windows(state.id).first { $0.id == headline?.id }, period: nil)
        }
        guard let first = visible.first else { left = .cpu; right = .memory; return }
        if visible.count >= 2 { left = primary(first); right = primary(visible[1]); return }
        let available = first.quotaAvailable ? windows(first.id) : []
        if quotas[first.id]?.source == .customCommand, !available.isEmpty {
            let timed = available.allSatisfy { ($0.periodSeconds ?? 0) > 0 }
            let ordered = timed ? available.sorted { ($0.periodSeconds ?? 0) < ($1.periodSeconds ?? 0) } : available
            left = .quota(first.id, ordered[0], period: timed ? Self.period(ordered[0]) : nil)
            if ordered.count >= 2 {
                let other = timed ? ordered[ordered.count - 1] : ordered[1]
                right = .quota(first.id, other, period: timed ? Self.period(other) : nil)
            } else { right = .cpu }
            return
        }
        guard let shortest = available.sorted(by: Self.shortestFirst).first else {
            left = first.quotaAvailable ? .quota(first.id, nil, period: nil) : .sessions(first.id, count: count(first.id))
            right = .cpu
            return
        }
        left = .quota(first.id, shortest, period: Self.period(shortest))
        if available.count >= 2, let longest = available.filter({ $0.id != shortest.id }).sorted(by: Self.longestFirst).first {
            right = .quota(first.id, longest, period: Self.period(longest))
        } else { right = .cpu }
    }
    private static func minutes(_ window: QuotaWindow) -> Int {
        if let seconds = window.periodSeconds, seconds.isFinite, seconds > 0 { return Int(min(Double(Int.max / 2), max(1, seconds / 60))) }
        if let minutes = window.windowMinutes, minutes > 0 { return minutes }
        switch window.kind { case .session: return 300; case .weekly, .weeklyModel: return 10080; case .other: return 0 }
    }
    private static func tie(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        if (a.kind == .weeklyModel) != (b.kind == .weeklyModel) { return a.kind != .weeklyModel }
        return a.id < b.id
    }
    private static func shortestFirst(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        if (minutes(a) == 0) != (minutes(b) == 0) { return minutes(a) > 0 }
        return minutes(a) == minutes(b) ? tie(a, b) : minutes(a) < minutes(b)
    }
    private static func longestFirst(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        if (minutes(a) == 0) != (minutes(b) == 0) { return minutes(a) > 0 }
        return minutes(a) == minutes(b) ? tie(a, b) : minutes(a) > minutes(b)
    }
    public static func period(_ window: QuotaWindow) -> String {
        let value = minutes(window)
        if value == 0 { return "周期" }
        if value % 1440 == 0 { return "\(value / 1440)d" }
        if value % 60 == 0 { return "\(value / 60)h" }
        return "\(value)m"
    }
}

public extension IslandStore {
    var providerWings: ProviderWingLayout {
        ProviderWingLayout(providers: providerStates, quotas: quotas, health: health, sessions: displaySessions, mode: quotaDisplayMode)
    }
    var expandedMetricOptions: SystemMetricOptions {
        guard visibleProviderIDs.isEmpty else { return systemMetricOptions }
        var options = systemMetricOptions; options.cpu = true; options.memory = true
        return options
    }
    var collapsedMetricOptions: SystemMetricOptions {
        .init(network: false, fan: false, memory: providerWings.needsMemory, cpu: providerWings.needsCPU, gpu: false)
    }
}
