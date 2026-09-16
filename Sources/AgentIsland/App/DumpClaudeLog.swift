import Foundation
import IslandCore

struct DumpClaudeLog {
    static func run(diagnostics: ClaudeDiagnostics = .shared) async {
        for line in await diagnostics.recentLines() { print(line) }
    }
}
