import Foundation

/// Reachability is injected so IslandCore tests never consult the host network.
/// The live SystemConfiguration implementation belongs to the app target.
public protocol ClaudeReachabilityChecking: Sendable {
    func isReachable() async -> Bool
}

public struct AssumedClaudeReachability: ClaudeReachabilityChecking {
    public init() {}
    public func isReachable() async -> Bool { true }
}
