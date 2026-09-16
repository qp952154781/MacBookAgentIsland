import AppKit
import Foundation
import Testing
@testable import AgentIsland

@MainActor @Test func guiEntryCannotSuspendBeforeApplicationRun() throws {
    // This assignment fails compilation if GUI startup becomes async.
    let entry: @MainActor (LaunchOptions, NSApplication) -> Void = AgentIslandEntry.runGUI
    _ = entry
    let loginEntry: @MainActor (LaunchOptions.LoginItemAction) throws -> Int32 = LoginItemCommand.run
    _ = loginEntry
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("Sources/AgentIsland/App/Entry.swift"), encoding: .utf8)
    let start = try #require(source.range(of: "static func main() async {"))
    let end = try #require(source.range(of: "    // NSApplication.run"))
    var main = String(source[start.lowerBound..<end.lowerBound])
    let loginBranch = try #require(main.range(of: "if let action = options.loginItem {\n                exit(try LoginItemCommand.run(action))\n            }"))
    let application = try #require(main.range(of: "let app = NSApplication.shared"))
    #expect(loginBranch.upperBound < application.lowerBound)
    // Only these terminating audit branches may suspend. Any await on the
    // remaining GUI path resumes inside dispatch main and breaks AppKit dispatch.
    let audit = try NSRegularExpression(pattern: #"if (options.dump == "(sessions|quota|system|claude-log)"|let directory = options.snapshotDirectory|options.measure, NotchGeometry.preferred\(\) == nil) \{[^{}]*\}"#)
    let matches = audit.matches(in: main, range: NSRange(main.startIndex..., in: main))
    #expect(matches.count == 6)
    for match in matches.reversed() {
        let range = try #require(Range(match.range, in: main))
        let branch = String(main[range])
        #expect(branch.contains("return") || branch.contains("exit(await DumpQuota.run())"))
        main.removeSubrange(range)
    }
    #expect(main.range(of: #"\bawait\b"#, options: .regularExpression) == nil)
    #expect(main.contains("runGUI(options: options, app: app)"))
    #expect(!source.contains("AUDIT TEST"))
}
