import Foundation

public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    case thinking, runningTool, waitingPermission, waitingInput, compacting, retrying, error, idle, ended
    public var isWorking: Bool {
        switch self {
        case .thinking, .runningTool, .compacting, .retrying: true
        default: false
        }
    }
    public var needsAttention: Bool { self == .waitingPermission || self == .error }
    public var label: String {
        switch self {
        case .thinking: "思考中"
        case .runningTool: "执行中"
        case .waitingPermission: "等待授权"
        case .waitingInput: "等待输入"
        case .compacting: "压缩上下文"
        case .retrying: "重试中"
        case .error: "出错"
        case .idle: "空闲"
        case .ended: "已结束"
        }
    }
}

public struct PlanProgress: Codable, Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var current: String?
    public init(completed: Int, total: Int, current: String? = nil) {
        self.completed = completed
        self.total = total
        self.current = current
    }
    public var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
}

public struct ContextUsage: Codable, Sendable, Equatable {
    public var usedTokens: Int
    public var windowTokens: Int?
    public init(usedTokens: Int, windowTokens: Int? = nil) {
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
    }
    public var fraction: Double? {
        guard let windowTokens, windowTokens > 0 else { return nil }
        return max(0, Double(usedTokens) / Double(windowTokens))
    }
}

public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agent: ProviderID
    public var sessionId: String
    public var title: String
    public var cwd: String?
    public var projectName: String?
    public var origin: String?
    public var model: String?
    public var phase: SessionPhase
    public var activity: String?
    public var lastPrompt: String?
    public var plan: PlanProgress?
    public var context: ContextUsage?
    public var turnStartedAt: Date?
    public var turnEndedAt: Date?
    public var toolCallsThisTurn: Int
    public var lastActivityAt: Date
    public var isAlive: Bool?
    /// Changes only when a new Codex token_count line is consumed.
    public var tokenCountRevision: String?

    public init(agent: ProviderID, sessionId: String, title: String, cwd: String? = nil,
                projectName: String? = nil, origin: String? = nil, model: String? = nil,
                phase: SessionPhase = .idle, activity: String? = nil, lastPrompt: String? = nil,
                plan: PlanProgress? = nil, context: ContextUsage? = nil, turnStartedAt: Date? = nil,
                turnEndedAt: Date? = nil, toolCallsThisTurn: Int = 0, lastActivityAt: Date,
                isAlive: Bool? = nil, tokenCountRevision: String? = nil) {
        self.id = "\(agent.rawValue):\(sessionId)"
        self.agent = agent
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.projectName = projectName ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.origin = origin
        self.model = model
        self.phase = phase
        self.activity = activity
        self.lastPrompt = lastPrompt
        self.plan = plan
        self.context = context
        self.turnStartedAt = turnStartedAt
        self.turnEndedAt = turnEndedAt
        self.toolCallsThisTurn = toolCallsThisTurn
        self.lastActivityAt = lastActivityAt
        self.isAlive = isAlive
        self.tokenCountRevision = tokenCountRevision
    }
}
