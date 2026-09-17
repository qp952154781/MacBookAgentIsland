import Foundation

/// Only a model name crosses this boundary; transcript metadata is never persisted.
public protocol ClaudeModelPersisting: Sendable {
    func loadModel() async -> String?
    func saveModel(_ model: String) async
}

@MainActor public final class ClaudeModelPreferences: ClaudeModelPersisting {
    public nonisolated static let key = "lastObservedClaudeModel"
    private let defaults: any AppSettingsDefaults

    public init(defaults: any AppSettingsDefaults) { self.defaults = defaults }
    public func loadModel() -> String? { defaults.string(forKey: Self.key) }
    public func saveModel(_ model: String) { defaults.set(model, forKey: Self.key) }
}

/// Diagnostic --home keeps its model preference inside the supplied home, isolated from
/// both the host's defaults domain and the read-only Claude/Codex data directories.
public actor DiagnosticClaudeModelPreferences: ClaudeModelPersisting {
    private let url: URL

    public init(home: URL) {
        url = physicalURL(home).appendingPathComponent(
            "Library/Preferences/org.agentisland.AgentIsland.model-history.plist")
    }
    public func loadModel() -> String? {
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return nil }
        return values[ClaudeModelPreferences.key]
    }
    public func saveModel(_ model: String) {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: [ClaudeModelPreferences.key: model], format: .binary, options: 0) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { /* Keep the in-memory observation when preferences are not writable. */ }
    }
}
