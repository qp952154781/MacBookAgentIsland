import Foundation

struct CodexThread: Sendable, Equatable {
    var id: String
    var rollout: URL?
    var updated: Date
    var cwd: String?
    var source: String?
    var name: String?
    var title: String?
    var preview: String?
    var firstUserMessage: String?
    var model: String?
}

struct CodexRollout: SessionLogState {
    var cwd: String?
    var origin: String?
    var model: String?
    var turnID: String?
    var startedAt: Date?
    var endedAt: Date?
    var active = false
    var aborted = false
    var completed = false
    var toolCalls = 0
    var activity: String?
    var lastCompletedAction: String?
    var lastCompletedToolAction: String?
    var hasTurnStart = false
    var requiresEarlierContext: Bool { !hasTurnStart }
    private var tokenCountEvents = 0
    var tokenCountRevision: String?
    var itemPhase: SessionPhase = .thinking
    var compactionAt: Date?
    var lastPrompt: String?
    var plan: PlanProgress?
    var usedTokens: Int?
    var windowTokens: Int?
    var seenCalls: Set<String> = []
    var seenItems: Set<String> = []

    mutating func consume(_ object: SessionJSON) {
        guard let payload = object["payload"] as? SessionJSON else { return }
        let date = sessionDate(object["timestamp"])
        switch object["type"] as? String {
        case "session_meta":
            cwd = nonempty(payload["cwd"] as? String) ?? cwd
            origin = nonempty(payload["source"] as? String) ?? origin
        case "turn_context":
            cwd = nonempty(payload["cwd"] as? String) ?? cwd
            model = nonempty(payload["model"] as? String) ?? model
        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                let nextID = payload["turn_id"] as? String
                if active && nextID != nil && nextID == turnID { return }
                turnID = nextID
                hasTurnStart = true
                startedAt = sessionDate(payload["started_at"]) ?? date
                endedAt = nil; active = true; aborted = false; completed = false
                activity = nil; lastCompletedAction = nil; lastCompletedToolAction = nil
                itemPhase = .thinking; compactionAt = nil
                toolCalls = 0; plan = nil; lastPrompt = nil
                seenCalls.removeAll(); seenItems.removeAll()
                windowTokens = sessionInt(payload["model_context_window"]) ?? windowTokens
            case "task_complete", "turn_aborted":
                let closingID = payload["turn_id"] as? String
                // A tail may start with completion; accept it only when no other turn is known.
                guard turnID == nil || (closingID != nil && closingID == turnID) else { return }
                turnID = closingID ?? turnID
                active = false
                aborted = payload["type"] as? String == "turn_aborted"
                completed = !aborted
                endedAt = sessionDate(payload["completed_at"]) ?? date
                startedAt = startedAt ?? sessionDate(payload["started_at"])
                activity = lastCompletedAction
            case "token_count":
                // Replaying the same tail must not invent a new revision. The sequence still
                // distinguishes separate token_count lines with identical payload/timestamps.
                tokenCountEvents += 1
                tokenCountRevision = "\(date?.timeIntervalSince1970 ?? 0):\(tokenCountEvents)"
                if let info = payload["info"] as? SessionJSON {
                    usedTokens = sessionInt((info["last_token_usage"] as? SessionJSON)?["input_tokens"]) ?? usedTokens
                    windowTokens = sessionInt(info["model_context_window"]) ?? windowTokens
                }
            case "item_completed":
                guard belongsToTurn(payload), let item = payload["item"] as? SessionJSON else { return }
                if let id = item["id"] as? String, !seenItems.insert(id).inserted { return }
                consumeItem(item, date: date)
            case "plan_update":
                guard belongsToTurn(payload) else { return }
                if let entries = payload["plan"] as? [SessionJSON] { plan = sessionPlan(entries) }
            default: break
            }
        case "response_item":
            guard belongsToTurn(payload) else { return }
            let type = payload["type"] as? String ?? ""
            guard ["function_call", "custom_tool_call"].contains(type) else { return }
            if let id = payload["call_id"] as? String, !seenCalls.insert(id).inserted { return }
            toolCalls += 1
            if payload["name"] as? String == "update_plan" {
                let args = (payload["arguments"] as? String).flatMap { sessionJSON(Data($0.utf8)) } ?? payload["arguments"] as? SessionJSON
                if let entries = args?["plan"] as? [SessionJSON] { plan = sessionPlan(entries) }
            }
        default: break
        }
    }

    private func belongsToTurn(_ payload: SessionJSON) -> Bool {
        guard active else { return false }
        guard let id = payload["turn_id"] as? String else { return true }
        return turnID == nil || turnID == id
    }

    private mutating func consumeItem(_ item: SessionJSON, date: Date?) {
        let type = (item["type"] as? String ?? "").replacingOccurrences(of: "_", with: "").lowercased()
        guard ["commandexecution", "filechange", "mcptoolcall", "websearch", "extension",
               "contextcompaction", "usermessage", "agentmessage", "reasoning", "imageview", "plan"].contains(type) else { return }
        itemPhase = .thinking; activity = nil; compactionAt = nil
        switch type {
        case "commandexecution":
            let parsed = (item["parsed_cmd"] as? [SessionJSON])?.first?["cmd"] as? String
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            activity = "执行 " + cleanSessionText(nonempty(parsed) ?? command, limit: 40)
            itemPhase = .runningTool; toolCalls += 1
        case "filechange":
            let files = (item["changes"] as? SessionJSON).map { Array($0.keys).sorted() }
                ?? (item["changes"] as? [SessionJSON])?.compactMap { $0["path"] as? String } ?? []
            activity = files.count == 1 ? "修改 " + URL(fileURLWithPath: files[0]).lastPathComponent : "修改 \(files.count) 个文件"
            itemPhase = .runningTool; toolCalls += 1
        case "mcptoolcall":
            activity = (item["server"] as? String ?? "MCP") + " · " + (item["tool"] as? String ?? "工具")
            itemPhase = .runningTool; toolCalls += 1
        case "websearch", "extension": activity = "搜索网页"; itemPhase = .runningTool
        case "contextcompaction": activity = "压缩上下文"; itemPhase = .compacting; compactionAt = date
        case "usermessage":
            let text = item["content"] as? String ?? (item["content"] as? [SessionJSON])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            lastPrompt = nonempty(firstPromptLine(text))
        case "plan":
            if let entries = item["plan"] as? [SessionJSON] ?? item["steps"] as? [SessionJSON] { plan = sessionPlan(entries) }
        default: break
        }
        activity = activity.map { cleanSessionText($0, limit: 60) }
        if let activity { lastCompletedAction = activity }
        if ["commandexecution", "filechange", "mcptoolcall", "websearch", "extension", "imageview"].contains(type), let activity {
            lastCompletedToolAction = activity
        }
    }

    func session(thread: CodexThread, modified: Date, now: Date) -> AgentSession {
        var phase: SessionPhase = active ? itemPhase : completed ? .waitingInput : .idle
        var action = activity ?? lastCompletedAction
        if phase == .waitingInput {
            action = lastCompletedToolAction ?? (hasTurnStart
                ? (toolCalls == 0 ? "本轮无工具调用" : "本轮工具调用已完成")
                : "本轮工具记录不完整")
        }
        if active && now.timeIntervalSince(modified) >= 1200 { phase = .idle; action = "无响应" }
        else if phase == .compacting && now.timeIntervalSince(compactionAt ?? modified) >= 5 { phase = .thinking; action = nil }
        let directory = cwd ?? nonempty(thread.cwd)
        let project = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未知项目"
        let title: String
        if let name = nonempty(thread.name) { title = cleanSessionText(name, limit: 40) }
        else { title = nonempty(codexHeading(nonempty(thread.title) ?? nonempty(thread.preview) ?? nonempty(thread.firstUserMessage) ?? "")) ?? project }
        return AgentSession(agent: .codex, sessionId: thread.id, title: cleanSessionText(title, limit: 40), cwd: directory,
                            projectName: project, origin: origin ?? thread.source, model: model ?? thread.model,
                            phase: phase, activity: action, lastPrompt: lastPrompt, plan: plan,
                            context: usedTokens.map { ContextUsage(usedTokens: $0, windowTokens: windowTokens) },
                            turnStartedAt: startedAt, turnEndedAt: endedAt, toolCallsThisTurn: toolCalls,
                            lastActivityAt: modified, tokenCountRevision: tokenCountRevision)
    }
}
