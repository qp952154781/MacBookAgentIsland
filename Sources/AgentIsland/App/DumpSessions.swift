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

    @MainActor static func run() async throws {
        let now = Date()
        let claude = ClaudeSessionProvider()
        let codex = CodexSessionProvider()
        async let claudeSessions = claude.currentSessions(now: now)
        async let codexSessions = codex.currentSessions(now: now)
        let collected = await claudeSessions + codexSessions
        let settings = AppSettings(defaults: UserDefaults.standard)
        let notch = NotchGeometry.preferred(useMainScreen: settings.useMainScreen)?.metrics
        let columns = notch.map {
            SessionListLayout(mode: settings.sessionListLayout,
                              activeCount: collected.filter { $0.phase != .ended }.count, notch: $0).columns
        } ?? 1
        let sessions = displayPayload(collected, columns: columns)
        let report = await DumpSessions(generatedAt: now, sessions: sessions,
                                        diagnostics: Diagnostics(claude: claude.diagnostics, codex: codex.diagnostics),
                                        warnings: ["claude": claude.diagnosticMessage().map { [$0] } ?? [],
                                                   "codex": codex.diagnosticMessage().map { [$0] } ?? []])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    static func displayPayload(_ input: [AgentSession], columns: Int) -> Sessions {
        guard columns == 2 else { return .merged(displaySessions(input)) }
        let groups = SessionDisplayOrder.columns(input).map { redactPrompts($0) }
        return .columns(claude: groups[0], codex: groups[1])
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
