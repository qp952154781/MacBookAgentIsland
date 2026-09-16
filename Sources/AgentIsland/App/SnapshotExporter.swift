import AppKit
import SwiftUI
import IslandCore

@MainActor enum SnapshotExporter {
    static let now = Date(timeIntervalSince1970: 1789182000)

    static func export(to directory: String) async throws {
        let officialGlyphs = BrandGlyphLoader()
        let fallbackGlyphs = BrandGlyphLoader(applicationDirectories: [])
        await officialGlyphs.refresh()
        await fallbackGlyphs.refresh()
        var cases: [(String, MockScenario, IslandMode, Bool)] = [
            ("collapsed-idle", .idle, .collapsed, true), ("collapsed-badge", .busy, .active, true), ("collapsed-active", .busy, .active, true),
            ("collapsed-both-active", .busy, .active, true),
            ("active-determinate", .busy, .active, true),
            ("active-indeterminate", .busy, .active, true),
            ("active-loading", .busy, .active, true),
            ("active-unavailable", .busy, .active, true),
            ("no-notch-active-determinate", .busy, .active, false),
            ("no-notch-active-indeterminate", .busy, .active, false),
            ("no-notch-active-loading", .busy, .active, false),
            ("no-notch-active-unavailable", .busy, .active, false),
            ("collapsed-active-narrow", .busy, .active, true),
            ("collapsed-left-active", .busy, .active, true), ("collapsed-right-active", .busy, .active, true),
            ("expanded-recovering", .idle, .expanded, true), ("expanded-recovering-empty", .idle, .expanded, true), ("expanded-refreshing", .idle, .expanded, true), ("expanded-setup", .idle, .expanded, true), ("expanded-login", .idle, .expanded, true),
            ("expanded-system-cpu-warning", .idle, .expanded, true),
            ("expanded-system-cpu-critical", .idle, .expanded, true),
            ("no-notch-system-cpu-warning", .idle, .expanded, false),
            ("no-notch-system-cpu-critical", .idle, .expanded, false),
            ("expanded-system-spacing-9", .idle, .expanded, true),
            ("expanded-system-spacing-100", .idle, .expanded, true),
            ("no-notch-system-spacing-9", .idle, .expanded, false),
            ("no-notch-system-spacing-100", .idle, .expanded, false),
            ("expanded-system-cpu-single", .idle, .expanded, true),
            ("expanded-system-cpu-loading", .idle, .expanded, true),
            ("expanded-system-fan", .idle, .expanded, true),
            ("expanded-system-no-fan", .idle, .expanded, true),
            ("expanded-system-memory-warning", .idle, .expanded, true),
            ("expanded-system-memory-critical", .idle, .expanded, true),
            ("expanded-system-stopped", .idle, .expanded, true),
            ("expanded-system-disabled", .idle, .expanded, true),
            ("expanded-busy", .busy, .expanded, true),
            ("sessions-auto-4", .idle, .expanded, true),
            ("sessions-auto-5", .idle, .expanded, true),
            ("sessions-grid-12", .idle, .expanded, true),
            ("sessions-grid-12-no-notch", .idle, .expanded, false),
            ("sessions-single-12", .idle, .expanded, true),
            ("sessions-double-2", .idle, .expanded, true),
            ("sessions-grid-detail", .idle, .expanded, true),
            ("sessions-grid-detail-recovering", .idle, .expanded, true),
            ("sessions-grid-capped", .idle, .expanded, true),
            ("sessions-grid-narrow", .idle, .expanded, false),
            ("collapsed-brand-fallback", .busy, .active, true),
            ("expanded-brand-fallback", .busy, .expanded, true),
            ("expanded-critical", .critical, .expanded, true), ("expanded-disconnected", .disconnected, .expanded, true),
            ("expanded-idle", .idle, .expanded, true),
            ("expanded-used", .idle, .expanded, true), ("expanded-fallback", .idle, .expanded, true),
            ("expanded-expired", .idle, .expanded, true), ("expanded-full", .idle, .expanded, true),
            ("collapsed-full", .idle, .collapsed, true), ("collapsed-full-narrow", .idle, .collapsed, true),
            ("expanded-loading", .idle, .expanded, true), ("expanded-stale", .idle, .expanded, true),
            ("expanded-failed", .idle, .expanded, true), ("expanded-detail", .busy, .expanded, true),
            ("expanded-many", .busy, .expanded, true), ("collapsed-narrow", .critical, .collapsed, true), ("no-notch-collapsed", .idle, .collapsed, false), ("no-notch-expanded", .busy, .expanded, false), ("no-notch-active", .busy, .active, false)
        ]
        for hasNotch in [true, false] {
            for scenario in ["unbalanced", "empty-claude", "empty-codex", "both-empty", "details", "left-detail", "narrow"] {
                cases.append(("sessions-agents-" + scenario + (hasNotch ? "" : "-no-notch"), .idle, .expanded, hasNotch))
            }
        }
        var files: [String: Data] = [:]
        for (name, scenario, mode, hasNotch) in cases {
            let store = IslandStore.mock(scenario, now: now)
            store.systemMetrics = SystemMetrics(
                network: .init(downBytesPerSec: 2.5 * 1024 * 1024, upBytesPerSec: 180 * 1024, interfaces: ["en0"]),
                fan: .init(fans: [.init(index: 0, rpm: 2507, minRPM: 2317, maxRPM: 6550)]),
                memory: .init(usedBytes: 72 * 1024, totalBytes: 100 * 1024), cpu: .init(percent: 12, sampleIntervalMs: 1000))
            if name.contains("system-spacing") {
                let percent = name.hasSuffix("-9") ? 9 : 100
                store.systemMetrics.cpu = .init(percent: Double(percent), sampleIntervalMs: 1000)
                store.systemMetrics.memory = .init(usedBytes: UInt64(percent), totalBytes: 100)
                store.systemMetrics.fan = .init(fans: [.init(index: 0, rpm: percent == 9 ? 0 : 2500,
                                                           minRPM: 0, maxRPM: 6550)])
            }
            switch name {
            case "expanded-system-cpu-warning", "no-notch-system-cpu-warning":
                store.systemMetrics.cpu = .init(percent: 85, sampleIntervalMs: 1000)
                store.systemMetrics.fan = .init(fans: [.init(index: 0, rpm: 0, minRPM: 0, maxRPM: 6550)])
            case "expanded-system-cpu-critical", "no-notch-system-cpu-critical":
                store.systemMetrics.cpu = .init(percent: 100, sampleIntervalMs: 1000)
            case "expanded-system-cpu-single": store.systemMetrics.cpu = .init(percent: 9, sampleIntervalMs: 1000)
            case "expanded-system-cpu-loading": store.systemMetrics.cpu = nil
            case "expanded-system-no-fan": store.systemMetrics.fan = nil
            case "expanded-system-memory-warning", "expanded-system-memory-critical":
                store.systemMetrics.memory = .init(usedBytes: name.hasSuffix("critical") ? 92 : 82, totalBytes: 100)
                store.systemMetrics.fan = .init(fans: [.init(index: 0, rpm: 5500, minRPM: 2317, maxRPM: 6550)])
            case "expanded-system-stopped":
                store.systemMetrics.fan = .init(fans: [.init(index: 0, rpm: 0, minRPM: 0, maxRPM: 6550)])
            case "expanded-system-disabled": store.systemMetricOptions = .init(network: false, fan: false, memory: false, cpu: false)
            case "expanded-refreshing", "expanded-recovering", "expanded-recovering-empty", "expanded-setup", "expanded-login":
                var status = ClaudeConnectionStatus()
                status.isRefreshing = name == "expanded-refreshing"
                status.isRecovering = name.contains("recovering") || status.isRefreshing
                status.requiresUserAction = !status.isRecovering
                status.result = name == "expanded-setup" ? .needsUserSetup("需要在终端完成一次 Claude Code 首次设置") : name == "expanded-login" ? .needsLogin : nil
                store.claudeConnection = status
                if name == "expanded-recovering-empty" { store.quotas[.claude] = nil }
                store.quotas[.claude]?.fetchedAt = now.addingTimeInterval(-720)

            case "active-determinate", "no-notch-active-determinate":
                for index in store.sessions.indices { store.sessions[index].plan = PlanProgress(completed: 3, total: 7, current: "验证") }
            case "active-indeterminate", "no-notch-active-indeterminate":
                for index in store.sessions.indices { store.sessions[index].plan = nil }
            case "active-loading", "no-notch-active-loading": store.quotas = [:]; store.health = [:]
            case "active-unavailable", "no-notch-active-unavailable": store.quotas = [:]
            case "collapsed-left-active": store.sessions.removeAll { $0.agent == .codex }
            case "collapsed-right-active": store.sessions.removeAll { $0.agent == .claude }
            case "expanded-used": store.quotaDisplayMode = .used
            case "expanded-fallback": store.quotas[.claude]?.windows.removeAll { $0.kind == .session }
            case "expanded-expired": store.quotas[.claude]?.windows[0].resetsAt = now.addingTimeInterval(-7200)
            case "collapsed-full", "collapsed-full-narrow", "expanded-full":
                for agent in AgentKind.allCases {
                    if let indices = store.quotas[agent]?.windows.indices {
                        for index in indices { store.quotas[agent]?.windows[index].usedPercent = 0 }
                    }
                }
                if name == "collapsed-full-narrow" { store.wingWidth = 60 }
            case "expanded-loading": store.quotas = [:]; store.health = [:]; store.lastRefresh = nil; store.sessionsLoaded = false
            case "expanded-stale": store.health[.claude] = .stale(lastSuccess: now.addingTimeInterval(-720))
            case "expanded-failed": store.quotas[.codex] = nil; store.health[.codex] = .failed(message: "本地服务暂时不可用")
            case "expanded-detail":
                store.sessions = Array(store.sessions.prefix(1))
                if let id = store.sessions.first?.id {
                    store.expandedSessionIDs = [id]
                    store.sessions[0].lastPrompt = "为会话增加详情，并检查很长的输入文本能否正确显示。"
                }
            case "expanded-many":
                for index in 0..<47 {
                    store.sessions.append(AgentSession(agent: .codex, sessionId: "more-\(index)",
                        title: "一个需要在中间省略的很长会话标题，用于验证长名称展示和列表滚动", cwd: "/fixture/project",
                        phase: .waitingInput, activity: "修改 3 个文件", lastActivityAt: now))
                }
            case "collapsed-badge":
                store.sessions += AgentKind.allCases.map { agent in
                    AgentSession(agent: agent, sessionId: "badge", title: "额外工作会话", phase: .thinking,
                                 lastActivityAt: now.addingTimeInterval(-10))
                }
            case "collapsed-narrow", "collapsed-active-narrow": store.wingWidth = 60
            default: break
            }
            var notch = metrics(hasNotch: hasNotch)
            if name.hasPrefix("sessions-") {
                let count = name == "sessions-auto-4" ? 4 : name == "sessions-auto-5" ? 5 : name == "sessions-double-2" ? 2 : 12
                store.sessions = sessionGridFixtures(count: count)
                if name == "sessions-single-12" { store.sessionListLayout = .singleColumn }
                if name == "sessions-double-2" { store.sessionListLayout = .twoColumns }
                if name.hasPrefix("sessions-grid-detail"), let first = store.displaySessions.first {
                    store.expandedSessionIDs = [first.id]
                }
                if name == "sessions-grid-detail-recovering" {
                    store.quotas[.claude]?.windows.append(QuotaWindow(id: "extra", kind: .weeklyModel, label: "额外窗口", usedPercent: 30))
                    var status = ClaudeConnectionStatus()
                    status.isRecovering = true
                    store.claudeConnection = status
                }
                if name == "sessions-grid-narrow" || name == "sessions-grid-capped" {
                    let width: CGFloat = name == "sessions-grid-narrow" ? 860 : 938
                    notch.visibleFrame = CGRect(x: notch.notchRect.midX - width / 2, y: 0, width: width, height: 900)
                }
            }
            if name.hasPrefix("sessions-agents-") {
                store.sessions = agentColumnFixtures(claude: 2, codex: 10)
                store.sessionListLayout = .twoColumns
                if name.contains("empty-claude") { store.sessions.removeAll { $0.agent == .claude } }
                if name.contains("empty-codex") { store.sessions.removeAll { $0.agent == .codex } }
                if name.contains("both-empty") { store.sessions = [] }
                if name.contains("details") || name.contains("left-detail") {
                    store.sessions = agentColumnFixtures(claude: 5, codex: 7)
                    let groups = name.contains("left-detail") ? Array(store.displaySessionColumns.prefix(1)) : store.displaySessionColumns
                    store.expandedSessionIDs = Set(groups.compactMap { $0.first?.id })
                }
                if name.contains("narrow") {
                    notch.visibleFrame = CGRect(x: notch.notchRect.midX - 430, y: 0, width: 860, height: 900)
                }
            }
            for debug in [false, true] {
                let view = SnapshotScene(store: store, notch: notch, mode: mode, debug: debug, now: now)
                    .environment(\.brandGlyphLoader, name.contains("brand-fallback") ? fallbackGlyphs : officialGlyphs)
                let renderer = ImageRenderer(content: view)
                renderer.scale = hasNotch ? 2 : 1
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw ExportError.renderFailed(name)
                }
                files[name + (debug ? "-debug" : "") + ".png"] = data
            }
        }
        // Render actual indicator layers at two discrete animation times, with no GUI window.
        for fallback in [false, true] {
            for agent in AgentKind.allCases {
                for time in [0.0, 1.0] {
                    let indicator = IndicatorView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
                    indicator.configure(kind: agent == .claude ? .claude : .codex,
                                        color: NSColor(Theme.glyph(agent)).cgColor, running: true,
                                        glyph: (fallback ? fallbackGlyphs : officialGlyphs).glyph(for: agent))
                    let name = "rotation-\(agent.rawValue)-\(fallback ? "fallback" : "official")-t\(Int(time))"
                    guard let image = indicator.snapshot(at: time, scale: 8),
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw ExportError.renderFailed(name)
                    }
                    files[name + ".png"] = data
                }
            }
        }
        for method in ExpansionMethod.allCases {
            let settings = AppSettings()
            settings.expansionMethod = method
            let renderer = ImageRenderer(content: SettingsView(settings: settings, store: IslandStore.mock(.idle, now: now),
                                                                 connection: ConnectionActions(), snapshot: true, snapshotDate: now))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw ExportError.renderFailed("settings")
            }
            files[method == .hover ? "settings.png" : "settings-click.png"] = data
        }
        for setup in [false, true] {
            let store = IslandStore.mock(.idle, now: now)
            var status = ClaudeConnectionStatus()
            status.expiresAt = now.addingTimeInterval(setup ? -300 : 25_000)
            status.lastAttempt = now.addingTimeInterval(-60)
            status.requiresUserAction = setup
            status.result = setup ? .needsUserSetup("需要在终端完成一次 Claude Code 首次设置") : .refreshed(status.expiresAt ?? now)
            store.claudeConnection = status
            let renderer = ImageRenderer(content: SettingsView(settings: AppSettings(), store: store, connection: ConnectionActions(), snapshot: true, snapshotDate: now))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ExportError.renderFailed("settings-claude") }
            files[setup ? "settings-claude-setup.png" : "settings-claude-refreshed.png"] = data
        }
        // Audit mode has no window. Disk writes run off the UI executor after all rendering completes.
        let renderedFiles = files
        try DispatchQueue.global(qos: .utility).sync {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, data) in renderedFiles { try data.write(to: url.appendingPathComponent(name), options: .atomic) }
        }
        print("已生成 \(files.count) 张快照：\(directory)")
    }

    static func metrics(hasNotch: Bool) -> NotchMetrics {
        let frame = CGRect(x: 0, y: 0, width: hasNotch ? 1512 : 3840, height: hasNotch ? 982 : 2160)
        return NotchMetrics(screenFrame: frame, safeAreaTop: hasNotch ? 32 : 0,
                            auxiliaryTopLeft: hasNotch ? CGRect(x: 0, y: 950, width: 665, height: 32) : nil,
                            auxiliaryTopRight: hasNotch ? CGRect(x: 850, y: 950, width: 662, height: 32) : nil,
                            menuBarHeight: hasNotch ? 24 : 22)
    }

    /// Hand-written, synthetic sessions shared by layout snapshots and integration tests.
    static func sessionGridFixtures(count: Int) -> [AgentSession] {
        let phases: [SessionPhase] = [.runningTool, .runningTool, .runningTool, .thinking, .compacting, .retrying,
                                     .waitingPermission, .waitingInput, .waitingInput, .error, .idle, .thinking]
        let projects: [String?] = ["灵动岛", "示例网站", "灵动岛", "示例网站", "示例网站", "这是一个需要优先保留但仍超出双列单元格宽度的很长示例项目名称",
                                  "灵动岛", "示例网站", nil, "示例网站", "灵动岛", nil]
        return (0..<count).reversed().map { index in
            AgentSession(agent: index.isMultiple(of: 2) ? .codex : .claude, sessionId: "grid-\(index)",
                         title: index == 0 ? "验证很长的会话标题在双列布局中的中间省略与显示，并确保状态和耗时完整可见" : "示例任务 \(index + 1)",
                         projectName: projects[index % projects.count], model: "示例模型",
                         phase: phases[index % phases.count],
                         activity: index == 0 ? "检查布局并运行本地验证命令以及一个很长的动作描述" : "检查布局并运行本地验证命令",
                         lastPrompt: "这是手写的脱敏样例，用于检查列内展开详情。",
                         context: ContextUsage(usedTokens: 48_000, windowTokens: 200_000),
                         turnStartedAt: now.addingTimeInterval(-Double((index + 1) * 60)), toolCallsThisTurn: index + 2,
                         lastActivityAt: now.addingTimeInterval(-Double(index * 10)))
        }
    }
    static func agentColumnFixtures(claude: Int, codex: Int) -> [AgentSession] {
        [AgentKind.claude, .codex].flatMap { agent in
            sessionGridFixtures(count: agent == .claude ? claude : codex).map { session in
                var result = session
                result.agent = agent
                result.id = "\(agent.rawValue):\(result.sessionId)"
                return result
            }
        }
    }
    enum ExportError: Error { case renderFailed(String) }
}

private struct SnapshotScene: View {
    let store: IslandStore
    let notch: NotchMetrics
    let mode: IslandMode
    let debug: Bool
    let now: Date
    private var canvasWidth: CGFloat { max(720, store.layoutConfig(notch: notch).expandedWidth + 120) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.22), Color(red: 0.065, green: 0.09, blue: 0.14),
                                    Color(red: 0.14, green: 0.11, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.065)).frame(height: 33)
            IslandRootView(store: store, notch: notch, mode: mode,
                           now: now, animated: false)
            if debug {
                Canvas { context, _ in
                    if notch.hasNotch {
                        context.stroke(Path(localRect(notch.notchRect).insetBy(dx: 0.5, dy: 0.5)), with: .color(.red), lineWidth: 1)
                    }
                    let wings = mode == .expanded && store.systemMetricOptions.enabled
                        ? IslandLayout.expandedWingRects(notch: notch, config: store.layoutConfig(notch: notch))
                        : IslandLayout.wingRects(notch: notch, config: store.layoutConfig)
                    for rect in [wings.left, wings.right] {
                        context.stroke(Path(localRect(rect).insetBy(dx: 0.5, dy: 0.5)), with: .color(.green), lineWidth: 1)
                    }
                }.allowsHitTesting(false)
            }
        }.frame(width: canvasWidth, height: 460).environment(\.colorScheme, .dark)
    }

    private func localRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX - notch.notchRect.midX + canvasWidth / 2, y: notch.screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
