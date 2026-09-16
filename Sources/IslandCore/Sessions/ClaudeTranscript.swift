import Foundation

struct ClaudeProcessEntry: Decodable, Sendable {
    let pid: Int32
    let sessionId: String
    var cwd: String?
    var entrypoint: String?
    var startedAt: Double?
    var version: String?
}

struct ClaudeTranscript: SessionLogState {
    var cwd: String?
    var origin: String?
    var model: String?
    var customTitle: String?
    var lastPrompt: String?
    var userPrompt: String?
    var turnStartedAt: Date?
    var turnEndedAt: Date?
    var context: ContextUsage?
    var plan: PlanProgress?
    var toolCalls = 0
    var lastMessage = ""
    var stopReason: String?
    var retry: String?
    var openTools: [String: String] = [:]
    var toolOrder: [String] = []
    var seenToolIDs: Set<String> = []
    var assistantID: String?
    var lastCompletedAction: String?

    mutating func consume(_ object: SessionJSON) {
        guard object["isSidechain"] as? Bool != true else { return }
        let type = object["type"] as? String ?? ""
        guard ["assistant", "user", "system", "custom-title", "last-prompt"].contains(type) else { return }
        cwd = nonempty(object["cwd"] as? String) ?? cwd
        origin = nonempty(object["entrypoint"] as? String) ?? origin
        let date = sessionDate(object["timestamp"])
        switch type {
        case "custom-title": customTitle = nonempty(object["customTitle"] as? String)
        case "last-prompt": lastPrompt = nonempty(object["lastPrompt"] as? String).map { firstPromptLine($0) }
        case "system":
            if object["subtype"] as? String == "api_error" {
                retry = "API 重试 \(sessionInt(object["retryAttempt"]) ?? 0)/\(sessionInt(object["maxRetries"]) ?? 0)"
            }
        case "user":
            guard let message = object["message"] as? SessionJSON else { return }
            let blocks = message["content"] as? [SessionJSON] ?? []
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            for result in results {
                if let id = result["tool_use_id"] as? String, let action = openTools.removeValue(forKey: id) { lastCompletedAction = action }
            }
            toolOrder.removeAll { openTools[$0] == nil }
            let text = message["content"] as? String ?? blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: " ")
            let isInput = object["isMeta"] as? Bool != true && results.isEmpty && nonempty(text) != nil
            guard isInput || !results.isEmpty else { return }
            if isInput {
                userPrompt = cleanSessionText(text, limit: 80)
                lastPrompt = firstPromptLine(text)
                turnStartedAt = date
                turnEndedAt = nil
                toolCalls = 0
                seenToolIDs.removeAll()
                openTools.removeAll()
                toolOrder.removeAll()
            }
            lastMessage = "user"
            retry = nil
        case "assistant":
            guard let message = object["message"] as? SessionJSON else { return }
            let id = message["id"] as? String
            // Split content blocks share stop_reason and usage; retain earlier non-null fields.
            if id == nil || id != assistantID { stopReason = nil }
            assistantID = id
            model = nonempty(message["model"] as? String) ?? model
            stopReason = message["stop_reason"] as? String ?? stopReason
            if let usage = message["usage"] as? SessionJSON {
                let values = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].map { sessionInt(usage[$0]) ?? 0 }
                let used = values.reduce(0) { partial, value in
                    let sum = partial.addingReportingOverflow(value)
                    return sum.overflow ? Int.max : sum.partialValue
                }
                context = ContextUsage(usedTokens: used, windowTokens: used > 200_000 ? 1_000_000 : 200_000)
            }
            for block in message["content"] as? [SessionJSON] ?? [] where block["type"] as? String == "tool_use" {
                guard let id = nonempty(block["id"] as? String), let name = block["name"] as? String else { continue }
                let input = block["input"] as? SessionJSON ?? [:]
                if seenToolIDs.insert(id).inserted {
                    toolCalls += 1
                    openTools[id] = Self.action(name: name, input: input)
                    toolOrder.append(id)
                }
                if name == "TodoWrite", let todos = input["todos"] as? [SessionJSON] { plan = sessionPlan(todos) }
            }
            lastMessage = "assistant"
            retry = nil
            if ["end_turn", "stop_sequence"].contains(stopReason ?? ""), openTools.isEmpty { turnEndedAt = date }
        default: break
        }
    }

    static func action(name: String, input: SessionJSON) -> String {
        let action: String
        switch name {
        case "Bash": action = "Bash · " + (nonempty(input["description"] as? String) ?? cleanSessionText(input["command"] as? String ?? "", limit: 40))
        case "Read", "Edit", "Write", "MultiEdit":
            let verb = name == "Read" ? "读取" : name == "Write" ? "写入" : "编辑"
            action = verb + " " + URL(fileURLWithPath: input["file_path"] as? String ?? "").lastPathComponent
        case "WebSearch": action = "搜索网页"
        case "WebFetch": action = "抓取网页"
        case "Agent", "Task": action = "子代理 · " + (input["description"] as? String ?? "")
        default:
            let parts = name.components(separatedBy: "__")
            action = parts.count >= 3 && parts[0] == "mcp" ? parts[1] + " · " + parts.dropFirst(2).joined(separator: "__") : name
        }
        return cleanSessionText(action, limit: 60)
    }

    func session(id: String, process: ClaudeProcessEntry?, alive: Bool, desktopTitle: String?, modified: Date, now: Date) -> AgentSession {
        var phase: SessionPhase = .idle
        var activity: String? = lastCompletedAction
        if let retry { phase = .retrying; activity = retry }
        else if let tool = toolOrder.last.flatMap({ openTools[$0] }) { phase = .runningTool; activity = tool }
        else if lastMessage == "user" { phase = .thinking }
        else if lastMessage == "assistant" {
            phase = ["end_turn", "stop_sequence"].contains(stopReason ?? "") ? .waitingInput : .thinking
        }
        if !alive { phase = .ended }
        else if now.timeIntervalSince(modified) >= 1800 && !phase.isWorking { phase = .idle }
        let directory = nonempty(process?.cwd) ?? cwd
        let project = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未知项目"
        let title = nonempty(desktopTitle) ?? nonempty(customTitle) ?? nonempty(userPrompt) ?? project
        return AgentSession(agent: .claude, sessionId: id, title: cleanSessionText(title, limit: 40), cwd: directory,
                            projectName: project, origin: process?.entrypoint ?? origin, model: model, phase: phase,
                            activity: activity, lastPrompt: lastPrompt, plan: plan, context: context,
                            turnStartedAt: turnStartedAt, turnEndedAt: turnEndedAt, toolCallsThisTurn: toolCalls,
                            lastActivityAt: modified, isAlive: alive)
    }
}
