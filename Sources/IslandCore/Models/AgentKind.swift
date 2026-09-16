import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claude, codex
    public var displayName: String { self == .claude ? "Claude" : "Codex" }
}
