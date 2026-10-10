import AppKit
import IslandCore

/// Reads the GUI's preferences even when launched as an unbundled command-line binary.
@MainActor protocol SessionDumpDefaults {
    func persistentDomain(forName domainName: String) -> [String: Any]?
}

extension UserDefaults: SessionDumpDefaults {}

struct DumpSessions: Encodable, Sendable {
    static let settingsDomain = "org.agentisland.AgentIsland"

    @MainActor private struct ReadOnlyDefaults: AppSettingsDefaults {
        let values: [String: Any]
        func string(forKey key: String) -> String? { values[key] as? String }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {}
    }

    @MainActor static func settings(defaults: any SessionDumpDefaults) -> AppSettings {
        // Diagnostic homes use the same user settings when present; an absent domain
        // falls back to AppSettings defaults without registering or writing preferences.
        AppSettings(defaults: ReadOnlyDefaults(values: defaults.persistentDomain(forName: settingsDomain) ?? [:]))
    }

    struct Entry: Encodable, Sendable {
        var session: AgentSession
        var visibility: SessionVisibility
        private enum CodingKeys: String, CodingKey { case shown, reason }
        func encode(to encoder: any Encoder) throws {
            try session.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(visibility.shown, forKey: .shown)
            try container.encode(visibility.reason, forKey: .reason)
        }
    }
    struct Diagnostics: Encodable, Sendable {
        var claude: ClaudeSessionDiagnostics
        var codex: CodexSessionDiagnostics
    }
    enum Sessions: Encodable, Sendable {
        case merged([Entry])
        case columns(claude: [Entry], codex: [Entry])

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
    var activeWindowMinutes: Int
    var sessions: Sessions
    var diagnostics: Diagnostics
    var warnings: [String: [String]]

    @MainActor static func run(home: URL? = nil, defaults: any SessionDumpDefaults = UserDefaults.standard) async throws {
        let report = await collect(home: home, defaults: defaults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    @MainActor static func collect(home: URL? = nil, now: Date = Date(),
                                   defaults: any SessionDumpDefaults = UserDefaults.standard) async -> DumpSessions {
        let paths = SessionPaths(home: home ?? FileManager.default.homeDirectoryForCurrentUser)
        let claude = ClaudeSessionProvider(paths: paths)
        let codex = CodexSessionProvider(paths: paths)
        let settings = settings(defaults: defaults)
        let activeWindow = Double(settings.activeMinutes) * 60
        await claude.setActiveWindow(activeWindow)
        let detection = await ProviderDetector(home: paths.home, diagnosticHome: home != nil).detect()
        let states = ProviderAvailability.resolve(detection: detection, overrides: settings.providerOverrides)
        let ids = states.filter(\.sessionsAvailable).map(\.id)
        async let claudeSessions = ids.contains(.claude) && detection.installed[.claude] == true ? claude.currentSessions(now: now) : []
        async let codexSessions = ids.contains(.codex) && detection.installed[.codex] == true ? codex.currentSessions(now: now) : []
        let collected = await claudeSessions + codexSessions
        let shown = SessionVisibilityPolicy.shownSessions(collected, now: now, activeWindow: activeWindow)
        let notch = home == nil ? NotchGeometry.preferred(useMainScreen: settings.useMainScreen)?.metrics : nil
        let columns = notch.map {
            SessionListLayout(mode: ids.count == 2 ? settings.sessionListLayout : .singleColumn,
                              activeCount: shown.filter { $0.phase != .ended }.count, notch: $0).columns
        } ?? 1
        let sessions = displayPayload(collected, columns: columns, providers: ids, now: now, activeWindow: activeWindow)
        return await DumpSessions(generatedAt: now, activeWindowMinutes: settings.activeMinutes, sessions: sessions,
                                 diagnostics: Diagnostics(claude: claude.diagnostics, codex: codex.diagnostics),
                                 warnings: ["claude": claude.diagnosticMessage().map { [$0] } ?? [],
                                            "codex": codex.diagnosticMessage().map { [$0] } ?? []])
    }

    static func displayPayload(_ input: [AgentSession], columns: Int, providers: [ProviderID] = ProviderRegistry.orderedIDs,
                               now: Date = Date(), activeWindow: TimeInterval = 1800) -> Sessions {
        let visibility = SessionVisibilityPolicy.decisions(for: input, now: now, activeWindow: activeWindow)
        func entries(_ sessions: [AgentSession]) -> [Entry] {
            sessions.compactMap { session in visibility[session.id].map { Entry(session: session, visibility: $0) } }
        }
        guard columns == 2 else { return .merged(entries(displaySessions(input))) }
        let groups = Dictionary(uniqueKeysWithValues: zip(providers,
            SessionDisplayOrder.columns(input, providers: providers).map { entries(redactPrompts($0)) }))
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
