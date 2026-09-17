import Foundation

public enum QuotaWindowKind: String, Codable, Sendable { case session, weekly, weeklyModel, other }
public enum QuotaLevel: String, Codable, Sendable { case normal, warning, critical }
public enum QuotaSource: String, Codable, Sendable {
    case codexAppServer, codexRollout, claudeOAuth, claudeStatusLine, mock
}

public struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: QuotaWindowKind
    public var label: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, kind: QuotaWindowKind, label: String, usedPercent: Double,
                windowMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public func elapsedFraction(now: Date) -> Double? {
        guard let windowMinutes, windowMinutes > 0, let resetsAt else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / (Double(windowMinutes) * 60)))
    }

    public var level: QuotaLevel {
        usedPercent >= 90 ? .critical : usedPercent >= 70 ? .warning : .normal
    }
}

public struct QuotaSnapshot: Codable, Sendable, Equatable {
    public var agent: ProviderID
    public var plan: String?
    public var windows: [QuotaWindow]
    public var source: QuotaSource
    public var fetchedAt: Date

    public init(agent: ProviderID, plan: String? = nil, windows: [QuotaWindow], source: QuotaSource, fetchedAt: Date) {
        self.agent = agent
        self.plan = plan
        self.windows = windows
        self.source = source
        self.fetchedAt = fetchedAt
    }

    public var weekly: QuotaWindow? { windows.first { $0.kind == .weekly } }
    public var session: QuotaWindow? { windows.first { $0.kind == .session } }
    public var headline: QuotaWindow? { weekly ?? windows.max { $0.usedPercent < $1.usedPercent } }
}

public enum ProviderHealth: Codable, Sendable, Equatable {
    case ok
    case stale(lastSuccess: Date)
    case needsSetup(message: String)
    case failed(message: String)
    case disabled
}
