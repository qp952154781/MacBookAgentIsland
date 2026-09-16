import Foundation
import SQLite3
import Testing
@testable import IslandCore

@Test func oversizedAndInvalidUTF8LinesRecoverAcrossBatches() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let url = try fixture.write(String(repeating: "x", count: JSONLTailer.maximumLineBytes + 1), "tail.jsonl")
    let tailer = JSONLTailer(url: url)
    #expect(await tailer.readNewLines().isEmpty)
    #expect(await tailer.skippedLines == 1)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([10, 0xff, 10]) + Data("{\"ok\":true}\npartial".utf8))
    try handle.close()
    #expect(await tailer.readNewLines() == [Data("{\"ok\":true}".utf8)])
    #expect(await tailer.skippedLines == 2)
    try fixture.write("{}\n", "tail.jsonl")
    #expect(await tailer.readNewLines() == [Data("{}".utf8)])
    #expect(await tailer.wasTruncated)
    #expect(await tailer.skippedLines == 0)
}

@Test func sqliteExclusiveLockFallsBackAndRecoversReadOnly() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let id = "12345678-1234-1234-1234-123456789012"
    let url = try fixture.write(try codexLine("event_msg", ["type": "task_started", "turn_id": "one"]),
                                fixture.rolloutPath(id: id, date: sessionTestNow))
    try fixture.modified(sessionTestNow, url)
    var database: OpaquePointer?
    let databaseURL = fixture.paths.codex.appendingPathComponent("state_1.sqlite")
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let db = try #require(database)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, updated_at_ms INTEGER, archived INTEGER); BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
    let provider = CodexSessionProvider(paths: fixture.paths)
    #expect(await provider.currentSessions(now: sessionTestNow).count == 1)
    #expect(await provider.diagnosticMessage() != nil)
    #expect(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
    #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    #expect(await provider.diagnosticMessage() == nil)
}

@Test func fiftyTranscriptSessionsRemainIncremental() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    for index in 0..<50 {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        let url = try fixture.write(try codexLine("event_msg", ["type": "task_started", "turn_id": "one"]),
                                    fixture.rolloutPath(id: id, date: sessionTestNow))
        try fixture.modified(sessionTestNow, url)
    }
    let provider = CodexSessionProvider(paths: fixture.paths)
    #expect(await provider.currentSessions(now: sessionTestNow).count == 50)
    #expect(await provider.currentSessions(now: sessionTestNow).count == 50)
    #expect(await provider.diagnostics.parsedBytes == 0)
}

@Test func clockExtremesNeverOverflowDisplay() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(DisplayTime.reset(Date(timeIntervalSince1970: 1e100), now: now) == "时间异常")
    #expect(DisplayTime.reset(Date(timeIntervalSince1970: .infinity), now: now) == "时间异常")
    #expect(DisplayTime.reset(now.addingTimeInterval(-1), now: now) == "—")
    #expect(DisplayTime.duration(.infinity) == "--")
}

@Test func largeValidHistoricalRecordAndInitialHalfLineDoNotWarn() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let record = try codexLine("response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 3_000_000)])
    let url = try fixture.write(record + (try codexLine("event_msg", ["type": "token_count"])), "large.jsonl")
    let tailer = JSONLTailer(url: url, initialTailBytes: 1_048_576)
    #expect(await tailer.readNewLines().count == 1)
    #expect(await tailer.skippedLines == 0)
    var log = SessionLog<CodexRollout>(url: url)
    _ = await log.read(url: url)
    #expect(log.warning == nil)
}

@Test func claudeRefreshProcessesAndTranscriptsAreExcluded() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let cwd = ClaudeRefreshDirectory.url(home: fixture.root).path
    let process = ["pid": 123, "sessionId": "refresh-process", "cwd": cwd] as [String: Any]
    let encoded = try JSONSerialization.data(withJSONObject: process)
    try fixture.write(String(decoding: encoded, as: UTF8.self), ".claude/sessions/123.json")
    for (id, directory) in [("refresh-process", "/fixture/other"), ("refresh-transcript", cwd), ("normal", "/fixture/normal")] {
        let url = try fixture.write(try claudeLine("user", message: ["content": "handwritten fixture"], extra: ["cwd": directory]), ".claude/projects/fixture/\(id).jsonl")
        try fixture.modified(sessionTestNow, url)
    }
    let encodedProject = cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
    let noCWD = try fixture.write(try claudeLine("user", extra: ["cwd": NSNull()]), ".claude/projects/\(encodedProject)/refresh-without-cwd.jsonl")
    try fixture.modified(sessionTestNow, noCWD)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness())
    #expect(await provider.currentSessions(now: sessionTestNow).map(\.sessionId) == ["normal"])
    #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: []).map(\.sessionId) == ["normal"])
    // The process registration can disappear while the transcript remains.
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".claude/sessions/123.json"))
    let refresh = try fixture.write(try claudeLine("user", extra: ["cwd": cwd + "/"]), ".claude/projects/fixture/refresh-process.jsonl")
    try fixture.modified(sessionTestNow, refresh)
    #expect(await provider.currentSessions(now: sessionTestNow).map(\.sessionId) == ["normal"])
}
