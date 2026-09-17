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
        return ProviderAvailability.resolve(detection: detection, overrides: settings.providerOverrides, latestClaudeModel: model)
    }
    @MainActor static func run(home: URL? = nil) async throws {
        let report = await states(home: home)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
