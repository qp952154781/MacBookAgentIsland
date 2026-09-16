import Foundation
import SQLite3
import Testing
@testable import IslandCore

struct SessionFixture {
    let root: URL
    var paths: SessionPaths { SessionPaths(home: root) }
    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent(".build/m2-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func write(_ text: String, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    func modified(_ date: Date, _ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    func rolloutPath(id: String, date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: ".codex/sessions/%04d/%02d/%02d/rollout-fixture-%@.jsonl", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1, id)
    }
}

struct FixtureLiveness: ProcessLiveness {
    var pids: Set<Int32> = [123]
    func isClaudeAlive(pid: Int32) -> Bool { pids.contains(pid) }
}

let sessionTestNow = Date(timeIntervalSince1970: 1_789_200_000)

func claudeLine(_ type: String, message: SessionJSON = [:], extra: SessionJSON = [:]) throws -> String {
    var object: SessionJSON = ["type": type, "timestamp": sessionTestNow.ISO8601Format(), "message": message, "cwd": "/fixture/项目"]
    object.merge(extra) { _, new in new }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
}
func codexLine(_ type: String, _ payload: SessionJSON, date: Date = sessionTestNow) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": date.ISO8601Format(), "payload": payload]), as: UTF8.self) + "\n"
}
func feed<State: SessionLogState>(_ state: inout State, _ lines: String) {
    for line in lines.split(separator: "\n") {
        if let object = sessionJSON(Data(line.utf8)) { state.consume(object) }
    }
}
func sampleThread() -> CodexThread {
    CodexThread(id: "thread", updated: sessionTestNow, cwd: "/fixture/项目", source: "exec")
}
func claudeSession(_ state: ClaudeTranscript, alive: Bool = true, now: Date = sessionTestNow, title: String? = nil) -> AgentSession {
    state.session(id: "session", process: nil, alive: alive, desktopTitle: title, modified: sessionTestNow, now: now)
}
