import Foundation
import IslandCore

struct DumpProviders {
    @MainActor static func states(home: URL? = nil) async -> [ProviderState] {
        let root = home ?? FileManager.default.homeDirectoryForCurrentUser
        let detection = await ProviderDetector(home: root, diagnosticHome: home != nil).detect()
        let settings = AppSettings(defaults: home == nil ? UserDefaults.standard : nil)
        var model: String?
        if detection.installed[.claude] == true {
            let preferences: any ClaudeModelPersisting = if let home {
                DiagnosticClaudeModelPreferences(home: home)
            } else {
                ClaudeModelPreferences(defaults: UserDefaults.standard)
            }
            // Share the parser's active/persisted/bootstrap precedence with the GUI.
            let provider = ClaudeSessionProvider(paths: SessionPaths(home: root), modelPreferences: preferences)
            _ = await provider.currentSessions(now: Date())
            model = await provider.latestObservedModel()
        }
        var resolvedDetection = detection
        for source in settings.customSources { resolvedDetection.installed[source.id] = true }
        return ProviderAvailability.resolve(declarations: settings.declarations, detection: resolvedDetection, overrides: settings.providerOverrides, latestClaudeModel: model)
    }
    struct Entry: Encodable {
        let state: ProviderState
        let status: CustomRunStatus?
        enum CodingKeys: String, CodingKey { case id, name, enabled, lastRunAt, lastStatus }
        func encode(to encoder: any Encoder) throws {
            if ProviderRegistry.orderedIDs.contains(state.id) { try state.encode(to: encoder); return }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state.id, forKey: .id)
            try container.encode(state.name, forKey: .name)
            try container.encode(state.enabled, forKey: .enabled)
            try container.encode(status?.time, forKey: .lastRunAt)
            try container.encode(status?.category, forKey: .lastStatus)
        }
    }
    static func encoded(states: [ProviderState], statuses: [ProviderID: CustomRunStatus] = [:]) throws -> Data {
        let report = states.map { Entry(state: $0, status: statuses[$0.id]) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
    @MainActor static func run(home: URL? = nil, mock: MockScenario? = nil) async throws {
        let report: [ProviderState]
        if let mock { report = IslandStore.mock(mock).providerStates }
        else { report = await states(home: home) }
        print(String(decoding: try encoded(states: report, statuses: await CustomCommandRunner.shared.statuses), as: UTF8.self))
    }
}
