import Foundation
import Testing
@testable import IslandCore

@Test func claudeMainChainSplitMessagesAndTools() throws {
    var state = ClaudeTranscript()
    feed(&state, try claudeLine("user", message: ["content": "  实现\n 中文标题  "]))
    #expect(claudeSession(state).phase == .thinking)
    let tool: SessionJSON = ["type": "tool_use", "id": "bash", "name": "Bash", "input": ["command": "swift build", "description": "构建\n  项目"]]
    feed(&state, try claudeLine("assistant", message: ["id": "a", "model": "claude-fixture", "content": [tool], "stop_reason": "tool_use"]))
    feed(&state, try claudeLine("assistant", message: ["id": "a", "content": [["type": "text", "text": "继续"]], "usage": ["input_tokens": 1000, "cache_read_input_tokens": 210000, "cache_creation_input_tokens": 2000]]))
    feed(&state, try claudeLine("assistant", message: ["id": "a", "content": [tool]]))
    let running = claudeSession(state)
    #expect(running.phase == .runningTool)
    #expect(running.activity == "Bash · 构建 项目")
    #expect(running.toolCallsThisTurn == 1)
    #expect(running.context == ContextUsage(usedTokens: 213000, windowTokens: 1000000))
    #expect(running.model == "claude-fixture")
    feed(&state, try claudeLine("user", message: ["content": [["type": "tool_result", "tool_use_id": "bash"]]], extra: ["isSidechain": true]))
    #expect(claudeSession(state).phase == .runningTool)
    feed(&state, try claudeLine("user", message: ["content": [["type": "tool_result", "tool_use_id": "bash"]]]))
    #expect(claudeSession(state).phase == .thinking)
    feed(&state, try claudeLine("assistant", message: ["id": "b", "content": [], "stop_reason": "end_turn"]))
    // A later split block with null stop_reason must retain end_turn.
    feed(&state, try claudeLine("assistant", message: ["id": "b", "content": [], "stop_reason": NSNull()]))
    #expect(claudeSession(state).phase == .waitingInput)
    #expect(claudeSession(state).activity == "Bash · 构建 项目")
    #expect(claudeSession(state, now: sessionTestNow.addingTimeInterval(1800)).activity == "Bash · 构建 项目")
    #expect(claudeSession(state, now: sessionTestNow.addingTimeInterval(1800)).phase == .idle)
    #expect(claudeSession(state, alive: false).phase == .ended)
    #expect(claudeSession(state).turnStartedAt == sessionTestNow)
    #expect(claudeSession(state).turnEndedAt == sessionTestNow)
    #expect(claudeSession(state).title == "实现 中文标题")
}

@Test func claudeRetryPlanTitlesAndBadLines() throws {
    var state = ClaudeTranscript()
    feed(&state, "bad json\n{}\n[]\n" + (try claudeLine("user", message: ["content": "用户标题"])))
    feed(&state, try claudeLine("custom-title", extra: ["customTitle": "自定义\n标题"]))
    #expect(claudeSession(state).title == "自定义 标题")
    #expect(claudeSession(state, title: "桌面标题").title == "桌面标题")
    feed(&state, try claudeLine("last-prompt", extra: ["lastPrompt": "最近\n 输入"]))
    #expect(claudeSession(state).lastPrompt == "最近")
    let todos: [SessionJSON] = [["content": "设计", "status": "completed"], ["content": "实现", "status": "in_progress", "activeForm": "正在实现"], ["content": "验证", "status": "pending"]]
    feed(&state, try claudeLine("assistant", message: ["id": "todo", "content": [["type": "tool_use", "id": "t", "name": "TodoWrite", "input": ["todos": todos]]]]))
    #expect(claudeSession(state).plan == PlanProgress(completed: 1, total: 3, current: "正在实现"))
    feed(&state, try claudeLine("system", extra: ["subtype": "api_error", "retryAttempt": 2, "maxRetries": 5]))
    feed(&state, try claudeLine("system", extra: ["subtype": "stop_hook_summary"]))
    #expect(claudeSession(state).phase == .retrying)
    #expect(claudeSession(state).activity == "API 重试 2/5")
    feed(&state, try claudeLine("user", message: ["content": "新一轮"]))
    #expect(claudeSession(state).phase == .thinking)
    #expect(claudeSession(state).toolCallsThisTurn == 0)
    feed(&state, try claudeLine("user", message: ["content": "元信息"], extra: ["isMeta": true]))
    #expect(claudeSession(state).lastPrompt == "新一轮")
    feed(&state, try claudeLine("assistant", message: ["id": "stop", "stop_reason": "stop_sequence", "content": []]))
    #expect(claudeSession(state).phase == .waitingInput)
}

@Test func claudeToolActionsAndUnicodeLimits() {
    for (name, input, expected) in [
        ("Read", ["file_path": "/tmp/中文.swift"], "读取 中文.swift"),
        ("Edit", ["file_path": "/tmp/a.swift"], "编辑 a.swift"),
        ("Write", ["file_path": "/tmp/a.swift"], "写入 a.swift"),
        ("MultiEdit", ["file_path": "/tmp/a.swift"], "编辑 a.swift"),
        ("Agent", ["description": "检查代码"], "子代理 · 检查代码"),
        ("WebSearch", [:], "搜索网页"), ("WebFetch", [:], "抓取网页"),
        ("mcp__fixture__search", [:], "fixture · search"), ("Unknown", [:], "Unknown")
    ] { #expect(ClaudeTranscript.action(name: name, input: input) == expected) }
    #expect(cleanSessionText(String(repeating: "中", count: 90), limit: 40).count == 40)
    #expect(ClaudeTranscript.action(name: "Agent", input: ["description": String(repeating: "文", count: 100)]).count == 60)
}

@Test func truncatedSessionTextEndsWithEllipsisWithinLimit() {
    // The reported case: a long command cut mid-word used to render as "…/run3/progre" with no marker.
    let command = "python3 -B docs/audit/D30-evidence/run3/progress_report.py --verbose"
    let cut = cleanSessionText(command, limit: 40)
    #expect(cut.count == 40)
    #expect(cut.hasSuffix("…"))
    #expect(cut == String(command.prefix(39)) + "…")
    // Untruncated text is returned unchanged, with whitespace collapsed and no marker.
    #expect(cleanSessionText("  swift   build \n --release ", limit: 40) == "swift build --release")
    #expect(cleanSessionText(String(repeating: "a", count: 40), limit: 40) == String(repeating: "a", count: 40))
    // Whitespace is not left dangling before the ellipsis.
    #expect(cleanSessionText("abcdefgh ijklmnop", limit: 10) == "abcdefgh…")
    // Grapheme clusters stay whole.
    let emoji = String(repeating: "👩‍💻", count: 12)
    #expect(cleanSessionText(emoji, limit: 5) == String(repeating: "👩‍💻", count: 4) + "…")
    #expect(cleanSessionText("中文标题很长很长很长", limit: 6) == "中文标题很…")
    // Degenerate limits never crash.
    #expect(cleanSessionText("abc", limit: 1) == "…")
    #expect(cleanSessionText("abc", limit: 0) == "")
}

@Test func claudeDiscoveryArchiveMetadataRefreshAndKeyExclusion() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    try fixture.write("{\"pid\":123,\"sessionId\":\"live\",\"cwd\":\"/fixture/project\",\"entrypoint\":\"claude-desktop\",\"startedAt\":1789200000000,\"version\":\"fixture\"}", ".claude/sessions/123.json")
    // Valid process JSON under a .key name must not be discovered or opened.
    let key = try fixture.write("{\"pid\":123,\"sessionId\":\"forbidden\"}", ".claude/sessions/123.fixture.key")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: key.path)
    try fixture.write("broken", ".claude/sessions/456.json")
    let log = try fixture.write(try claudeLine("user", message: ["content": "用户标题"]), ".claude/projects/encoded/live.jsonl")
    try fixture.modified(sessionTestNow, log)
    let recent = try fixture.write(try claudeLine("assistant", message: ["content": [], "stop_reason": "end_turn"]), ".claude/projects/encoded/recent.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-5), recent)
    let old = try fixture.write("{}\n", ".claude/projects/encoded/old.jsonl")
    try fixture.modified(sessionTestNow.addingTimeInterval(-2000), old)
    let metadata = try fixture.write("{\"cliSessionId\":\"live\",\"title\":\"桌面标题\",\"isArchived\":false}", "Library/Application Support/Claude/claude-code-sessions/a/b/local_live.json")
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(), clock: { sessionTestNow })
    let first = await provider.currentSessions()
    #expect(first.map(\.sessionId) == ["live", "recent"])
    #expect(first.first?.title == "桌面标题")
    #expect(first.first?.origin == "claude-desktop")
    #expect(first.last?.phase == .ended)
    #expect(await provider.diagnostics.processEntries == 2)
    #expect(await provider.diagnostics.liveProcesses == 1)
    #expect(await provider.currentSessions(now: sessionTestNow).count == 2)
    #expect(await provider.diagnostics.parsedBytes == 0)
    try Data("{\"cliSessionId\":\"live\",\"isArchived\":true}".utf8).write(to: metadata)
    try fixture.modified(sessionTestNow.addingTimeInterval(2), metadata)
    #expect(await provider.currentSessions(now: sessionTestNow).map(\.sessionId) == ["recent"])
}

@Test func claudeTailPerformanceIncrementalAndRotation() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    let previous = try claudeLine("custom-title", extra: ["customTitle": "不得读取文件头"])
    // Twenty MB of synthetic text, with a deliberately incomplete first tail line.
    let content = previous + String(repeating: "x", count: 20 * 1024 * 1024) + "\n" + (try claudeLine("user", message: ["content": "尾部标题"]))
    let url = try fixture.write(content, ".claude/projects/p/session.jsonl")
    try fixture.modified(sessionTestNow, url)
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    let scanStart = ContinuousClock.now
    let scanned = await provider.currentSessions(now: sessionTestNow)
    let scanDuration = scanStart.duration(to: .now)
    // Wall time is diagnostic only; the exact byte budget below verifies bounded IO.
    #expect(scanned.first?.title == "尾部标题")
    #expect(await provider.diagnostics.parsedBytes == 1_048_576)
    print("Synthetic 20MB transcript first provider scan: \(scanDuration)")
    var log = SessionLog<ClaudeTranscript>(url: url)
    let start = ContinuousClock.now
    let parsed = await log.read(url: url)
    let duration = start.duration(to: .now)
    print("Synthetic transcript tail read: \(duration)")
    #expect(parsed == 1_048_576)
    #expect(log.state.customTitle == nil)
    #expect(log.state.userPrompt == "尾部标题")
    let next = try claudeLine("assistant", message: ["id": "end", "content": [], "stop_reason": "end_turn"])
    let split = next.index(next.startIndex, offsetBy: next.count / 2)
    try fixture.append(String(next[..<split]), to: url)
    #expect(await log.read(url: url) == String(next[..<split]).utf8.count)
    try fixture.append(String(next[split...]), to: url)
    #expect(await log.read(url: url) > 0)
    #expect(claudeSession(log.state).phase == .waitingInput)
    try Data("{}\n".utf8).write(to: url, options: .atomic)
    _ = await log.read(url: url)
    #expect(log.state.userPrompt == nil)
    #expect(log.state.toolCalls == 0)
}

@Test func claudeRelevantSessionsSortedAndLimited() async throws {
    let fixture = try SessionFixture(); defer { fixture.remove() }
    for index in 0..<10 {
        let file = try fixture.write(try claudeLine("user", message: ["content": "会话 \(index)"]), ".claude/projects/project/id-\(index).jsonl")
        try fixture.modified(sessionTestNow.addingTimeInterval(-Double(index)), file)
    }
    let provider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness(pids: []))
    let sessions = await provider.currentSessions(now: sessionTestNow)
    #expect(sessions.map(\.sessionId) == (0..<10).map { "id-\($0)" })
    #expect(sessions.allSatisfy { $0.phase == .ended })
    try fixture.write("{\"pid\":123,\"sessionId\":\"id-9\",\"cwd\":\"/fixture/project\"}", ".claude/sessions/123.json")
    let liveProvider = ClaudeSessionProvider(paths: fixture.paths, liveness: FixtureLiveness())
    let later = await liveProvider.currentSessions(now: sessionTestNow.addingTimeInterval(2000))
    #expect(later.map(\.sessionId) == ["id-9"])
    // Working live sessions do not become idle merely because their transcript stopped changing.
    #expect(later.first?.phase == .thinking)
}
