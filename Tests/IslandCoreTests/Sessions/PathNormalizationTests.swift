import Foundation
import Darwin
import SQLite3
import Testing
@testable import IslandCore

private func physicalFixtureURL(_ url: URL) throws -> URL {
    let pointer = try #require(realpath(url.path, nil))
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}

private func fixtureLink(_ link: URL, to target: URL) throws {
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
}

struct PathNormalizationTests {
    @Test func rootsResolveHomeAndExplicitDirectoryLinks() throws {
        let fixture = try SessionFixture(); defer { fixture.remove() }
        let physical = try physicalFixtureURL(fixture.root)
        for relative in ["home/.claude", "home/.codex", "home/Library/Application Support/Claude/claude-code-sessions"] {
            try FileManager.default.createDirectory(at: physical.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let home = physical.appendingPathComponent("home", isDirectory: true)
        let alias = physical.appendingPathComponent("home-link", isDirectory: true)
        try fixtureLink(alias, to: home)
        let paths = SessionPaths(home: alias)
        #expect(paths.home.path == home.path)
        #expect(paths.claude.path == home.appendingPathComponent(".claude").path)
        #expect(paths.codex.path == home.appendingPathComponent(".codex").path)
        #expect(paths.claudeDesktopMetadata.path == home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions").path)
        let override = SessionPaths(home: home, claude: alias.appendingPathComponent(".claude"),
                                    codex: alias.appendingPathComponent(".codex"),
                                    claudeDesktopMetadata: alias.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"))
        #expect(override.claude.path == paths.claude.path)
        #expect(override.codex.path == paths.codex.path)
        #expect(override.claudeDesktopMetadata.path == paths.claudeDesktopMetadata.path)
    }

    @Test func linkedHomePhysicalEventsAndRefreshExclusion() async throws {
        try await checkClaudeHome(linkedHome: true)
    }

    @Test func physicalHomeLinkedEventsAndCWD() async throws {
        try await checkClaudeHome(linkedHome: false)
    }

    private func checkClaudeHome(linkedHome: Bool) async throws {
        let fixture = try SessionFixture(); defer { fixture.remove() }
        let physical = try physicalFixtureURL(fixture.root)
        let home = physical.appendingPathComponent("home", isDirectory: true)
        let alias = physical.appendingPathComponent("home-link", isDirectory: true)
        let refresh = ClaudeRefreshDirectory.url(home: home)
        try FileManager.default.createDirectory(at: refresh, withIntermediateDirectories: true)
        try fixtureLink(alias, to: home)
        let cwdHome = linkedHome ? home : alias
        let cwd = ClaudeRefreshDirectory.url(home: cwdHome).path
        let encodedProject = refresh.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        for (id, directory, project) in [
            ("normal", "/fixture/normal", "project"),
            ("refresh-process", "/fixture/other", "project"),
            ("refresh-cwd", cwd, "project"),
            ("refresh-no-cwd", "", encodedProject)
        ] {
            let file = try fixture.write(try claudeLine("user", extra: ["cwd": directory.isEmpty ? NSNull() : directory as Any]),
                                         "home/.claude/projects/\(project)/\(id).jsonl")
            try fixture.modified(sessionTestNow, file)
        }
        let process: SessionJSON = ["pid": 123, "sessionId": "refresh-process", "cwd": cwd]
        try fixture.write(String(decoding: JSONSerialization.data(withJSONObject: process), as: UTF8.self), "home/.claude/sessions/123.json")
        let provider = ClaudeSessionProvider(paths: SessionPaths(home: linkedHome ? alias : home), liveness: FixtureLiveness())
        #expect(await provider.currentSessions(now: sessionTestNow).map(\.sessionId) == ["normal"])
        let relative = ".claude/projects/project/new.jsonl"
        let file = try fixture.write(try claudeLine("user"), "home/" + relative)
        try fixture.modified(sessionTestNow, file)
        let changed = cwdHome.appendingPathComponent(relative).path
        let sessions = await provider.currentSessions(now: sessionTestNow, changedPaths: [changed])
        #expect(Set(sessions.map(\.sessionId)) == ["normal", "new"])
        let metadataPath = "Library/Application Support/Claude/claude-code-sessions/u/p/local_new.json"
        try fixture.write("{\"cliSessionId\":\"new\",\"title\":\"软链接元数据\"}", "home/" + metadataPath)
        let titled = await provider.currentSessions(now: sessionTestNow, changedPaths: [cwdHome.appendingPathComponent(metadataPath).path])
        #expect(titled.first { $0.sessionId == "new" }?.title == "软链接元数据")
        #expect(await provider.diagnostics.parsedBytes == 0)
        // Recovery events must invalidate descendants even through the opposite spelling.
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [cwdHome.path]).count == 2)
    }

    @Test func linkedClaudeDirectoryDiscoversPhysicalEvents() async throws {
        let fixture = try SessionFixture(); defer { fixture.remove() }
        let physical = try physicalFixtureURL(fixture.root)
        let first = try fixture.write(try claudeLine("user"), "dotfiles/claude/projects/p/first.jsonl")
        try fixture.modified(sessionTestNow, first)
        try fixtureLink(physical.appendingPathComponent(".claude"), to: physical.appendingPathComponent("dotfiles/claude"))
        let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
        #expect(await provider.currentSessions(now: sessionTestNow).count == 1)
        let second = try fixture.write(try claudeLine("user"), "dotfiles/claude/projects/p/second.jsonl")
        try fixture.modified(sessionTestNow, second)
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [second.path]).count == 2)
    }

    @Test func linkedCodexDirectoryDiscoveryAndIncrementalUpdates() async throws {
        let fixture = try SessionFixture(); defer { fixture.remove() }
        let physical = try physicalFixtureURL(fixture.root)
        let target = physical.appendingPathComponent("dotfiles/codex", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try fixtureLink(physical.appendingPathComponent(".codex"), to: target)
        let id = "12345678-1234-1234-1234-123456789012"
        let relative = fixture.rolloutPath(id: id, date: sessionTestNow)
        let initial = try codexLine("event_msg", ["type": "task_started", "turn_id": "one"])
        let file = try fixture.write(initial, relative)
        try fixture.modified(sessionTestNow, file)
        let actualFile = try physicalFixtureURL(file)
        let provider = CodexSessionProvider(paths: fixture.paths)
        #expect(await provider.currentSessions(now: sessionTestNow).first?.phase == .thinking)
        #expect(await provider.diagnostics.usedDirectoryFallback)
        let complete = try codexLine("event_msg", ["type": "task_complete", "turn_id": "one"])
        try fixture.append(complete, to: file)
        try fixture.modified(sessionTestNow, file)
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [actualFile.path]).first?.phase == .waitingInput)
        let completedBytes = await provider.diagnostics.parsedBytes
        #expect(completedBytes == complete.utf8.count)
        let next = try fixture.write(initial, fixture.rolloutPath(id: "12345678-1234-1234-1234-123456789013", date: sessionTestNow))
        try fixture.modified(sessionTestNow, next)
        let actualNext = try physicalFixtureURL(next)
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [actualNext.path]).count == 2)
        try fixture.append(initial, to: file)
        try fixture.modified(sessionTestNow, file)
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [file.path]).first { $0.sessionId == id }?.phase == .thinking)
        let restartedBytes = await provider.diagnostics.parsedBytes
        #expect(restartedBytes == initial.utf8.count)
        try FileManager.default.removeItem(at: file)
        #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [actualFile.deletingLastPathComponent().path]).count == 1)
    }

    @Test func linkedCodexSQLiteRolloutsUseSamePathsAsEvents() async throws {
        // Exercise physical, symlink and relative rollout_path values independently.
        for spelling in ["physical", "link", "relative"] {
            let fixture = try SessionFixture(); defer { fixture.remove() }
            let physical = try physicalFixtureURL(fixture.root)
            let target = physical.appendingPathComponent("dotfiles/codex", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let alias = physical.appendingPathComponent(".codex", isDirectory: true)
            try fixtureLink(alias, to: target)
            let id = "12345678-1234-1234-1234-123456789012"
            let relative = fixture.rolloutPath(id: id, date: sessionTestNow)
            let file = try fixture.write(try codexLine("event_msg", ["type": "task_started", "turn_id": "one"]), relative)
            try fixture.modified(sessionTestNow, file)
            let actual = try physicalFixtureURL(file)
            let indexedPath = spelling == "physical" ? actual.path : spelling == "link" ? file.path : String(relative.dropFirst(".codex/".count))
            var handle: OpaquePointer?
            #expect(sqlite3_open(target.appendingPathComponent("state_5.sqlite").path, &handle) == SQLITE_OK)
            let database = try #require(handle)
            defer { sqlite3_close(database) }
            #expect(sqlite3_exec(database, "CREATE TABLE threads (id TEXT, rollout_path TEXT, updated_at_ms INTEGER, archived INTEGER)", nil, nil, nil) == SQLITE_OK)
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(database, "INSERT INTO threads VALUES (?, ?, ?, 0)", -1, &statement, nil) == SQLITE_OK)
            let insert = try #require(statement)
            defer { sqlite3_finalize(insert) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(insert, 1, id, -1, transient)
            sqlite3_bind_text(insert, 2, indexedPath, -1, transient)
            sqlite3_bind_double(insert, 3, sessionTestNow.timeIntervalSince1970 * 1000)
            #expect(sqlite3_step(insert) == SQLITE_DONE)
            let paths = SessionPaths(home: fixture.root, codex: URL(fileURLWithPath: alias.path, isDirectory: false))
            let provider = CodexSessionProvider(paths: paths)
            #expect(await provider.currentSessions(now: sessionTestNow).first?.phase == .thinking)
            #expect(await provider.diagnostics.sqliteReadable)
            let complete = try codexLine("event_msg", ["type": "task_complete", "turn_id": "one"])
            try fixture.append(complete, to: file)
            try fixture.modified(sessionTestNow, file)
            let event = spelling == "physical" ? file.path : actual.path
            #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [event]).first?.phase == .waitingInput)
            let parsedBytes = await provider.diagnostics.parsedBytes
            #expect(parsedBytes == complete.utf8.count)
        }
    }

    @Test func missingPathsPreserveOriginalSpellingAndDoNotCrash() async throws {
        let fixture = try SessionFixture(); defer { fixture.remove() }
        let missing = URL(fileURLWithPath: fixture.root.path + "/missing/../absent", isDirectory: true)
        let paths = SessionPaths(home: missing, claude: missing, codex: missing, claudeDesktopMetadata: missing)
        #expect(paths.home.path == missing.path)
        #expect(paths.claude.path == missing.path)
        #expect(paths.codex.path == missing.path)
        #expect(paths.claudeDesktopMetadata.path == missing.path)
        #expect(!ClaudeRefreshDirectory.contains(missing.path, home: fixture.root))
        let broken = fixture.root.appendingPathComponent("broken-link")
        try fixtureLink(broken, to: missing)
        #expect(SessionPaths(home: broken).home.path == broken.path)
        let cycle = fixture.root.appendingPathComponent("cycle-link")
        try fixtureLink(cycle, to: cycle)
        #expect(SessionPaths(home: cycle).home.path == cycle.path)
        let providers: [any SessionProviding] = [ClaudeSessionProvider(paths: paths, liveness: FixtureLiveness()), CodexSessionProvider(paths: paths)]
        for provider in providers {
            #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
            #expect(await provider.currentSessions(now: sessionTestNow, changedPaths: [missing.path]).isEmpty)
        }
    }
}
