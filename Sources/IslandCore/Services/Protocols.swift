import Foundation

public enum QuotaError: Error, Sendable, Equatable {
    case notConfigured(String)
    case unauthorized(String)
    case transient(String)
    case decoding(String)
}
public protocol QuotaProviding: Sendable {
    var agent: ProviderID { get }
    func fetchQuota() async throws -> QuotaSnapshot
}
/// Local bootstrap can populate the first frame while the authoritative query runs.
public protocol InitialQuotaProviding: QuotaProviding {
    func initialQuota() async -> QuotaSnapshot?
}
public protocol SessionProviding: Sendable {
    var agent: ProviderID { get }
    /// Returns cached, incrementally read sessions that are alive or recently active.
    func diagnosticMessage() async -> String?
    func currentSessions(now: Date) async -> [AgentSession]
    /// nil requests discovery/reconciliation; paths request a selective refresh.
    func currentSessions(now: Date, changedPaths: Set<String>?) async -> [AgentSession]
    func parsedBytesLastScan() async -> Int
    /// Last parsed assistant model, retained independently of the active session window.
    func latestObservedModel() async -> String?
    /// Debounced paths, scoped to this provider. An empty set requests reconciliation.
    func changes() -> AsyncStream<Set<String>>
    func setActiveWindow(_ seconds: TimeInterval) async
}

public extension SessionProviding {
    func diagnosticMessage() async -> String? { nil }
    func setActiveWindow(_ seconds: TimeInterval) async {}
    func currentSessions(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        await currentSessions(now: now)
    }
    func parsedBytesLastScan() async -> Int { 0 }
    func latestObservedModel() async -> String? { nil }
}

public protocol QuotaServicing: Sendable {
    func setCustomSources(_ sources: [CustomSource]) async
    func setEnabledProviders(_ ids: [ProviderID]) async
    func retryClaudeConnection() async
    func setClaudeAutoRefresh(_ enabled: Bool) async
    func noteClaudeSuspension() async
    func noteClaudeResume() async
    func updates() async -> AsyncStream<QuotaUpdate>
    func start() async
    func stop() async
    func refreshNow(agent: ProviderID?) async
    func setInterval(_ seconds: TimeInterval) async
    func setSuspended(_ suspended: Bool) async
}

public extension QuotaServicing {
    func setCustomSources(_ sources: [CustomSource]) async {}
    func setEnabledProviders(_ ids: [ProviderID]) async {}
    func retryClaudeConnection() async { await refreshNow(agent: .claude) }
    func setClaudeAutoRefresh(_ enabled: Bool) async {}
    func noteClaudeSuspension() async {}
    func noteClaudeResume() async {}
    func setSuspended(_ suspended: Bool) async {}
}

public protocol SessionServicing: Sendable {
    func setEnabledProviders(_ ids: [ProviderID]) async
    func latestUpdate() async -> SessionUpdate?
    func updates() async -> AsyncStream<SessionUpdate>
    func start() async
    func stop() async
    func refreshNow() async
    func setActiveWindow(_ seconds: TimeInterval) async
    func setVisible(_ visible: Bool) async
}

public extension SessionServicing {
    func setEnabledProviders(_ ids: [ProviderID]) async {}
    func latestUpdate() async -> SessionUpdate? { nil }
    func setVisible(_ visible: Bool) async {}
}
