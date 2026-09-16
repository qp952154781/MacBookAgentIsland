import Foundation
import SQLite3
import Testing
@testable import IslandCore

@Test func codexTurnsActionsContextAndCompletion() throws {
    var state = CodexRollout()
    feed(&state, try codexLine("session_meta", ["cwd": "/fixture/项目", "source": "exec"]))
    feed(&state, try codexLine("turn_context", ["model": "model-fixture"]))
    feed(&state, try codexLine("event_msg", ["type": "task_started", "turn_id": "one", "started_at": sessionTestNow.timeIntervalSince1970, "model_context_window": 258400]))
    #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow).phase == .thinking)
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "UserMessage", "content": [["type": "text", "text": "# 首行标题\n详细内容"]]]]))
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "CommandExecution", "command": ["sh", "-c", "fallback"], "parsed_cmd": [["cmd": "swift build"]]]]))
    var session = state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow)
    #expect(session.phase == .runningTool)
    #expect(session.activity == "执行 swift build")
    #expect(session.lastPrompt == "首行标题")
    #expect(session.origin == "exec")
    #expect(session.model == "model-fixture")
    feed(&state, try codexLine("event_msg", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 42000]]]))
    #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow).context == ContextUsage(usedTokens: 42000, windowTokens: 258400))
    feed(&state, try codexLine("event_msg", ["type": "task_complete", "turn_id": "different"]))
    #expect(state.active)
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "fileChange", "changes": ["/tmp/中文.swift": ["type": "update"]]]]))
    #expect(state.activity == "修改 中文.swift")
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "FileChange", "changes": ["a": [:], "b": [:]]]]))
    #expect(state.activity == "修改 2 个文件")
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "mcpToolCall", "server": "fixture", "tool": "search"]]))
    #expect(state.activity == "fixture · search")
    #expect(state.toolCalls == 4)
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "different", "item": ["type": "CommandExecution"]]))
    #expect(state.toolCalls == 4)
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": ["type": "Reasoning"]]))
    #expect(state.itemPhase == .thinking)
    feed(&state, try codexLine("event_msg", ["type": "task_complete", "turn_id": "one", "completed_at": sessionTestNow.timeIntervalSince1970 + 10]))
    session = state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow)
    #expect(session.phase == .waitingInput)
    #expect(session.activity == "fixture · search")
    #expect(session.turnEndedAt == sessionTestNow.addingTimeInterval(10))
    feed(&state, try codexLine("response_item", ["type": "function_call", "name": "ignored"]))
    #expect(state.toolCalls == 4)
}

@Test func codexAbortedStalledCompactionAndPlans() throws {
    var state = CodexRollout()
    feed(&state, "bad\n{}\n" + (try codexLine("event_msg", ["type": "task_started", "turn_id": "one"])))
    for status in ["in_progress", "inProgress"] {
        let args = "{\"plan\":[{\"step\":\"设计\",\"status\":\"completed\"},{\"step\":\"实施\",\"status\":\"\(status)\"}]}"
        feed(&state, try codexLine("response_item", ["type": "function_call", "name": "update_plan", "arguments": args, "call_id": status]))
        #expect(state.plan == PlanProgress(completed: 1, total: 2, current: "实施"))
    }
    feed(&state, try codexLine("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "exec"]))
    feed(&state, try codexLine("response_item", ["type": "custom_tool_call", "name": "exec", "call_id": "exec"]))
    #expect(state.toolCalls == 3)
    feed(&state, try codexLine("event_msg", ["type": "plan_update", "plan": [["step": "完成", "status": "completed"]]]))
    #expect(state.plan == PlanProgress(completed: 1, total: 1))
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": "Plan", "plan": [["step": "继续", "status": "inProgress"]]]]))
    #expect(state.plan?.current == "继续")
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": "webSearch"]]))
    #expect(state.activity == "搜索网页")
    feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": "ContextCompaction"]]))
    #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow).phase == .compacting)
    #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow.addingTimeInterval(6)).phase == .thinking)
    let stalled = state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow.addingTimeInterval(1200))
    #expect(stalled.phase == .idle)
    #expect(stalled.activity == "无响应")
    feed(&state, try codexLine("event_msg", ["type": "turn_aborted", "turn_id": "one"]))
    #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow).activity == "压缩上下文")
    feed(&state, try codexLine("event_msg", ["type": "task_started", "turn_id": "two"]))
    #expect(state.active)
    #expect(state.toolCalls == 0)
    #expect(state.plan == nil)
    #expect(state.lastPrompt == nil)
}

@Test func codexTitleSanitizationAndPriority() {
    var thread = sampleThread()
    let state = CodexRollout()
    thread.title = "\n  # 【任务】 中文首行\n" + String(repeating: "长提示", count: 5000)
    thread.preview = "备用"
    #expect(state.session(thread: thread, modified: sessionTestNow, now: sessionTestNow).title == "任务 中文首行")
    thread.name = " 命名\n会话 "
    #expect(state.session(thread: thread, modified: sessionTestNow, now: sessionTestNow).title == "命名 会话")
    thread.name = " "; thread.title = ""; thread.preview = "预览"
    #expect(state.session(thread: thread, modified: sessionTestNow, now: sessionTestNow).title == "预览")
    thread.preview = nil; thread.firstUserMessage = "第一条"
    #expect(state.session(thread: thread, modified: sessionTestNow, now: sessionTestNow).title == "第一条")
    #expect(codexHeading("# 【】 -* ") == "")
    #expect(codexHeading("开头一句，" + String(repeating: "文", count: 60)) == "开头一句…")
    #expect(codexHeading(String(repeating: "中", count: 60)).count == 40)
}

@Test func codexWaitingInputKeepsLatestToolAcrossMessagesAndResetsEachTurn() throws {
    for (tool, expected) in [
        (["type": "CommandExecution", "command": "python3 fixture.py"], "执行 python3 fixture.py"),
        (["type": "FileChange", "changes": ["/fixture/a.swift": [:]]], "修改 a.swift"),
        (["type": "McpToolCall", "server": "fixture", "tool": "lookup"], "fixture · lookup")
    ] as [(SessionJSON, String)] {
        var state = CodexRollout()
        feed(&state, try codexLine("event_msg", ["type": "task_started", "turn_id": "one"]))
        feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "command": "earlier"]]))
        feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": tool]))
        for type in ["ContextCompaction", "Reasoning", "AgentMessage"] {
            feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": type]]))
        }
        feed(&state, try codexLine("event_msg", ["type": "task_complete", "turn_id": "one"]))
        var session = state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow)
        #expect(session.phase == .waitingInput)
        #expect(session.activity == expected)
        feed(&state, try codexLine("event_msg", ["type": "task_started", "turn_id": "two"]))
        #expect(state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow).activity == nil)
        feed(&state, try codexLine("event_msg", ["type": "item_completed", "turn_id": "one", "item": tool]))
        for type in ["Reasoning", "AgentMessage"] {
            feed(&state, try codexLine("event_msg", ["type": "item_completed", "item": ["type": type]]))
        }
        feed(&state, try codexLine("event_msg", ["type": "task_complete", "turn_id": "two"]))
        session = state.session(thread: sampleThread(), modified: sessionTestNow, now: sessionTestNow)
        #expect(session.phase == .waitingInput)
        #expect(session.activity == "本轮无工具调用")
        #expect(session.toolCallsThisTurn == 0)
    }
}

@Test func codexDirectoryFallbackIncrementalAndRelevance() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let id = "12345678-1234-1234-1234-123456789012"
    let url = try fixture.write(try codexLine("session_meta", ["source": "exec", "cwd": "/fixture/project"])
                               + codexLine("event_msg", ["type": "task_started", "turn_id": "one"]), fixture.rolloutPath(id: id, date: sessionTestNow))
    try fixture.modified(sessionTestNow, url)
    let provider = CodexSessionProvider(paths: fixture.paths, clock: { sessionTestNow })
    #expect(await provider.currentSessions().first?.phase == .thinking)
    #expect(await provider.diagnostics.usedDirectoryFallback)
    #expect(await provider.currentSessions().first?.title == "project")
    #expect(await provider.diagnostics.parsedBytes == 0)
    try fixture.append(try codexLine("event_msg", ["type": "task_complete", "turn_id": "one"]), to: url)
    try fixture.modified(sessionTestNow, url)
    #expect(await provider.currentSessions().first?.phase == .waitingInput)
    #expect(await provider.currentSessions(now: sessionTestNow.addingTimeInterval(1801)).isEmpty)
    try fixture.write("not sqlite", ".codex/state_99.sqlite")
    #expect(await provider.currentSessions().count == 1)
    #expect(await provider.diagnostics.sqliteReadable == false)
}

@Test func codexLongTurnRecoversToolBeforeInitialTailAndKeepsIncrementalReads() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let id = "12345678-1234-1234-1234-123456789012"
    let start = try codexLine("event_msg", ["type": "task_started", "turn_id": "long"])
    let command = try codexLine("event_msg", ["type": "item_completed", "turn_id": "long",
                                            "item": ["type": "CommandExecution", "command": "python3 fixture.py"]])
    let reasoning = try codexLine("event_msg", ["type": "item_completed", "turn_id": "long",
                                              "item": ["type": "Reasoning", "content": String(repeating: "x", count: 16384)]])
    let end = try codexLine("event_msg", ["type": "item_completed", "turn_id": "long", "item": ["type": "AgentMessage"]])
        + codexLine("event_msg", ["type": "task_complete", "turn_id": "long"])
    let file = try fixture.write(start + command + String(repeating: reasoning, count: 80) + end,
                                 fixture.rolloutPath(id: id, date: sessionTestNow))
    try fixture.modified(sessionTestNow, file)
    let provider = CodexSessionProvider(paths: fixture.paths, clock: { sessionTestNow })
    let session = try #require(await provider.currentSessions().first)
    #expect(session.phase == .waitingInput)
    #expect(session.activity == "执行 python3 fixture.py")
    #expect(session.toolCallsThisTurn == 1)
    #expect(await provider.diagnostics.parsedBytes > 1_048_576)
    #expect(await provider.currentSessions().first?.activity == session.activity)
    #expect(await provider.diagnostics.parsedBytes == 0)
    let next = try codexLine("event_msg", ["type": "task_started", "turn_id": "next"])
        + codexLine("event_msg", ["type": "item_completed", "turn_id": "next", "item": ["type": "AgentMessage"]])
        + codexLine("event_msg", ["type": "task_complete", "turn_id": "next"])
    try fixture.append(next, to: file)
    try fixture.modified(sessionTestNow, file)
    #expect(await provider.currentSessions().first?.activity == "本轮无工具调用")
    #expect(await provider.diagnostics.parsedBytes < 1024)
    try fixture.write(next, fixture.rolloutPath(id: id, date: sessionTestNow))
    try fixture.modified(sessionTestNow, file)
    #expect(await provider.currentSessions().first?.activity == "本轮无工具调用")
}

@Test func codexReadOnlySQLiteVersionSelectionAndOptionalColumns() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let id = "12345678-1234-1234-1234-123456789012"
    let rollout = try fixture.write(try codexLine("event_msg", ["type": "task_started", "turn_id": "one"]), fixture.rolloutPath(id: id, date: sessionTestNow))
    try fixture.modified(sessionTestNow, rollout)
    try fixture.write("broken old version", ".codex/state_9.sqlite")
    let databaseURL = fixture.paths.codex.appendingPathComponent("state_10.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &db) == SQLITE_OK)
    let database = try #require(db)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "CREATE TABLE threads (id TEXT, rollout_path TEXT, updated_at_ms INTEGER, archived INTEGER, name TEXT, title TEXT, cwd TEXT, source TEXT)", nil, nil, nil) == SQLITE_OK)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK)
    let insert = try #require(statement)
    defer { sqlite3_finalize(insert) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (rowID, age, archived) in [(id, 0.0, 0), ("archived", 0.0, 1), ("old", 90000.0, 0)] {
        sqlite3_reset(insert)
        sqlite3_bind_text(insert, 1, rowID, -1, transient)
        sqlite3_bind_text(insert, 2, rollout.path, -1, transient)
        sqlite3_bind_double(insert, 3, sessionTestNow.addingTimeInterval(-age).timeIntervalSince1970 * 1000)
        sqlite3_bind_int(insert, 4, Int32(archived))
        sqlite3_bind_text(insert, 5, "", -1, transient)
        sqlite3_bind_text(insert, 6, "# 数据库标题\n详情", -1, transient)
        sqlite3_bind_text(insert, 7, "/fixture/database-project", -1, transient)
        sqlite3_bind_text(insert, 8, "exec", -1, transient)
        #expect(sqlite3_step(insert) == SQLITE_DONE)
    }
    let original = try Data(contentsOf: databaseURL)
    let provider = CodexSessionProvider(paths: fixture.paths, clock: { sessionTestNow })
    let sessions = await provider.currentSessions()
    #expect(sessions.count == 1)
    #expect(sessions.first?.title == "数据库标题")
    #expect(sessions.first?.projectName == "database-project")
    #expect(await provider.diagnostics.sqliteReadable)
    #expect(await provider.diagnostics.sqliteThreads == 1)
    #expect(try Data(contentsOf: databaseURL) == original)
    #expect(sqlite3_exec(database, "UPDATE threads SET name = '更新后的名称' WHERE archived = 0", nil, nil, nil) == SQLITE_OK)
    #expect(await provider.currentSessions().first?.title == "更新后的名称")
}

@Test func codexYesterdayFallbackAndUnknownItems() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: sessionTestNow))
    for index in 0..<10 {
        let id = String(format: "12345678-1234-1234-1234-%012d", index)
        let file = try fixture.write(try codexLine("event_msg", ["type": "task_started", "turn_id": "one"])
                                    + codexLine("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "command": ["swift", "test"]]])
                                    + codexLine("event_msg", ["type": "item_completed", "item": ["type": "FutureType"]]), fixture.rolloutPath(id: id, date: yesterday))
        try fixture.modified(sessionTestNow.addingTimeInterval(-Double(index)), file)
    }
    let provider = CodexSessionProvider(paths: fixture.paths)
    let sessions = await provider.currentSessions(now: sessionTestNow)
    #expect(sessions.count == 10)
    #expect(sessions.first?.sessionId == "12345678-1234-1234-1234-000000000000")
    #expect(sessions.first?.activity == "执行 swift test")
    #expect(sessions.allSatisfy { $0.phase == .runningTool })
    #expect(await provider.currentSessions(now: sessionTestNow.addingTimeInterval(1201)).allSatisfy { $0.activity == "无响应" })
}

@Test func codexHeadingsStopAtEarliestBoundaryAndTokenRevision() throws {
    for boundary in ["（", "(", "【", "[", "《", "。", "！", "？", "；", "!", "?", ";"] {
        #expect(codexHeading("M1按任务书实施" + boundary + "项目守则，更多内容") == "M1按任务书实施")
    }
    #expect(codexHeading("标题。正文（说明）") == "标题")
    #expect(codexHeading("【M1】按任务书实施（项目守则）") == "M1按任务书实施")
    var state = CodexRollout()
    feed(&state, try codexLine("event_msg", ["type": "token_count", "info": [:]]))
    let first = state.tokenCountRevision
    #expect(first != nil)
    feed(&state, try codexLine("turn_context", ["model": "fixture"]))
    #expect(state.tokenCountRevision == first)
    feed(&state, try codexLine("event_msg", ["type": "token_count", "info": [:]]))
    #expect(state.tokenCountRevision != first)
}

@Test func providerDiagnosticsContainOnlyRelevantKeys() throws {
    let encoder = JSONEncoder()
    let claude = String(decoding: try encoder.encode(ClaudeSessionDiagnostics()), as: UTF8.self)
    let codex = String(decoding: try encoder.encode(CodexSessionDiagnostics()), as: UTF8.self)
    #expect(!claude.contains("sqlite"))
    #expect(!claude.contains("usedDirectoryFallback"))
    #expect(!codex.contains("processEntries"))
    #expect(!codex.contains("metadataEntries"))
}

@Test func providersHotUpdateActiveWindow() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let claudeFile = try fixture.write("{}\n", ".claude/projects/p/old.jsonl")
    let codexFile = try fixture.write("{}\n", fixture.rolloutPath(id: "12345678-1234-1234-1234-123456789012", date: sessionTestNow))
    try fixture.modified(sessionTestNow.addingTimeInterval(-2400), claudeFile)
    try fixture.modified(sessionTestNow.addingTimeInterval(-2400), codexFile)
    let providers: [any SessionProviding] = [ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: [])), CodexSessionProvider(paths: fixture.paths)]
    for provider in providers {
        #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
        await provider.setActiveWindow(3600)
        #expect(await provider.currentSessions(now: sessionTestNow).count == 1)
        await provider.setActiveWindow(900)
        #expect(await provider.currentSessions(now: sessionTestNow).isEmpty)
    }
}
