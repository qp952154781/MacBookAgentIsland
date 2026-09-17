import Foundation
import IslandCore

struct DumpClaudeLog {
    static func run(home: URL? = nil, diagnostics: ClaudeDiagnostics = .shared) async {
        let source = home.map { ClaudeDiagnostics(directory: $0.appendingPathComponent("Library/Application Support/AgentIsland/diagnostics")) } ?? diagnostics
        for line in await source.recentLines() { print(line) }
    }
}
