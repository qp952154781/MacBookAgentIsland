import Foundation

public struct IslandEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case turnCompleted(duration: TimeInterval?)
        case needsAttention(reason: String)
        case failed(message: String)
        case quotaThreshold(windowID: String, percent: Double)
    }
    public var id: UUID
    public var agent: ProviderID
    public var sessionID: String?
    public var title: String
    public var detail: String?
    public var kind: Kind
    public var date: Date

    public init(id: UUID = UUID(), agent: ProviderID, sessionID: String? = nil, title: String,
                detail: String? = nil, kind: Kind, date: Date) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.title = title
        self.detail = detail
        self.kind = kind
        self.date = date
    }
}
