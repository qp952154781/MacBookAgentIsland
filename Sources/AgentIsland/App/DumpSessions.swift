import AppKit
import IslandCore

struct DumpSessions: Encodable, Sendable {
    struct Diagnostics: Encodable, Sendable {
        var claude: ClaudeSessionDiagnostics
        var codex: CodexSessionDiagnostics
    }
    enum Sessions: Encodable, Sendable {
        case merged([AgentSession])
        case columns(claude: [AgentSession], codex: [AgentSession])

        private enum CodingKeys: String, CodingKey { case claude, codex }
        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .merged(sessions):
                var container = encoder.singleValueContainer()
                try container.encode(sessions)
            case let .columns(claude, codex):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(claude, forKey: .claude)
                try container.encode(codex, forKey: .codex)
            }
        }
    }
    var generatedAt: Date
    var sessions: Sessions
    var diagnostics: Diagnostics
    var warnings: [String: [String]]

    @MainActor static func run(home: URL? = nil) async throws {
        let now = Date()
        let paths = SessionPaths(home: home ?? FileManager.default.homeDirectoryForCurrentUser)
        let claude = ClaudeSessionProvider(paths: paths)
        let codex = CodexSessionProvider(paths: paths)
        let settings = AppSettings(defaults: home == nil ? UserDefaults.standard : nil)
        let detection = await ProviderDetector(home: paths.home, diagnosticHome: home != nil).detect()
        let states = ProviderAvailability.resolve(detection: detection, overrides: settings.providerOverrides)
        let ids = states.filter(\.sessionsAvailable).map(\.id)
        async let claudeSessions = ids.contains(.claude) && detection.installed[.claude] == true ? claude.currentSessions(now: now) : []
        async let codexSessions = ids.contains(.codex) && detection.installed[.codex] == true ? codex.currentSessions(now: now) : []
        let collected = await claudeSessions + codexSessions
        let notch = home == nil ? NotchGeometry.preferred(useMainScreen: settings.useMainScreen)?.metrics : nil
        let columns = notch.map {
            SessionListLayout(mode: ids.count == 2 ? settings.sessionListLayout : .singleColumn,
                              activeCount: collected.filter { $0.phase != .ended }.count, notch: $0).columns
        } ?? 1
        let sessions = displayPayload(collected, columns: columns, providers: ids)
        let report = await DumpSessions(generatedAt: now, sessions: sessions,
                                        diagnostics: Diagnostics(claude: claude.diagnostics, codex: codex.diagnostics),
                                        warnings: ["claude": claude.diagnosticMessage().map { [$0] } ?? [],
                                                   "codex": codex.diagnosticMessage().map { [$0] } ?? []])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    static func displayPayload(_ input: [AgentSession], columns: Int, providers: [ProviderID] = ProviderRegistry.orderedIDs) -> Sessions {
        guard columns == 2 else { return .merged(displaySessions(input)) }
        let groups = Dictionary(uniqueKeysWithValues: zip(providers,
            SessionDisplayOrder.columns(input, providers: providers).map { redactPrompts($0) }))
        return .columns(claude: groups[.claude] ?? [], codex: groups[.codex] ?? [])
    }

    static func displaySessions(_ input: [AgentSession]) -> [AgentSession] {
        redactPrompts(SessionDisplayOrder.sorted(input))
    }

    private static func redactPrompts(_ input: [AgentSession]) -> [AgentSession] {
        var sessions = input
        for index in sessions.indices {
            sessions[index].lastPrompt = sessions[index].lastPrompt.map { String($0.prefix(80)) }
        }
        return sessions
    }
}
