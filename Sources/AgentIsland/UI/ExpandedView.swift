import SwiftUI
import IslandCore

struct ExpandedView: View {
    let store: IslandStore
    let now: Date
    let availableHeight: CGFloat
    var columns = 1
    var animated = true
    var animationsVisible = true
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    var retry: (AgentKind) -> Void = { _ in }
    var openClaudeSetup: () -> Void = {}
    var copyLogin: (AgentKind) -> Void = { _ in }

    static func cardHeight(store: IslandStore) -> CGFloat {
        let count = store.quotas.values.map { $0.windows.count }.max() ?? 0
        let hasNote = store.quotas.values.contains { store.quotaDisplayMode.fallbackNote($0) != nil }
        return max(134, 50 + CGFloat(min(4, count)) * 27 + (hasNote ? 18 : 0)) + ((store.claudeConnection?.isRefreshing == true || store.claudeConnection?.isRecovering == true) && store.claudeConnection?.requiresUserAction != true ? 36 : 0)
    }
    static func overhead(store: IslandStore) -> CGFloat { cardHeight(store: store) + 84 }
    static func layoutConfig(store: IslandStore, notch: NotchMetrics) -> IslandLayoutConfig {
        var config = store.layoutConfig(notch: notch)
        let hasDetail = store.displaySessions.contains { store.expandedSessionIDs.contains($0.id) }
        let minimumRow = SessionListLayout.rowHeight + (hasDetail ? SessionListLayout.detailHeight : 0)
        // Extra quota windows and recovery notices must still leave room for one complete row.
        config.expandedMaxHeight = max(config.expandedMaxHeight, notch.notchRect.height + overhead(store: store) + minimumRow)
        return config
    }
    static func contentHeight(store: IslandStore, notch: NotchMetrics) -> CGFloat {
        let heights = store.sessionColumns(count: store.sessionLayout(notch: notch).columns).map {
            SessionListLayout.rowHeights(sessions: $0, expandedIDs: store.expandedSessionIDs)
        }
        return min(layoutConfig(store: store, notch: notch).expandedMaxHeight, notch.notchRect.height + overhead(store: store)
                   + max(44, heights.map { $0.prefix(4).reduce(0, +) }.max() ?? 0))
    }
    private var sessionColumns: [[AgentSession]] { store.sessionColumns(count: columns) }
    private var columnRowHeights: [[CGFloat]] {
        sessionColumns.map { SessionListLayout.rowHeights(sessions: $0, expandedIDs: store.expandedSessionIDs) }
    }
    private var documentHeight: CGFloat { max(44, columnRowHeights.map { $0.reduce(0, +) }.max() ?? 0) }
    private var availableRowsHeight: CGFloat { max(44, availableHeight - Self.overhead(store: store)) }
    private var viewportHeight: CGFloat {
        max(44, SessionListLayout.viewportHeight(columnRowHeights: columnRowHeights, available: availableRowsHeight))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: columns == 2 ? SessionListLayout.columnSpacing : 12) {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    QuotaCard(agent: agent, snapshot: store.quotas[agent], health: store.health[agent], now: now, connection: agent == .claude ? store.claudeConnection : nil, openSetup: openClaudeSetup, diagnostic: store.quotaDiagnostics[agent],
                              height: Self.cardHeight(store: store), warning: store.warningThreshold, critical: store.criticalThreshold,
                              displayMode: store.quotaDisplayMode,
                              retry: { retry(agent) }, copyLogin: { copyLogin(agent) })
                }
            }.padding(.top, 10)
            sessionHeader
                .font(Theme.font(10, weight: .medium)).frame(height: 16).padding(.top, 10).padding(.bottom, 4)
            if store.sessions.isEmpty && columns == 1 {
                HStack(spacing: 7) {
                    Image(systemName: "moon.zzz").font(.system(size: 13))
                    Text(store.sessionsLoaded ? (store.sessionWarnings.values.sorted().first ?? "暂无活跃会话") : "正在读取…").font(Theme.font(11))
                }.foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if documentHeight <= availableRowsHeight || !animated {
                sessionRows
                    .frame(height: viewportHeight, alignment: .top).clipped()
                    .coordinateSpace(name: Self.sessionViewportSpace)
                    .frame(height: availableRowsHeight, alignment: .top)
            } else {
                ScrollView { sessionRows }.scrollIndicators(.hidden)
                    .coordinateSpace(name: Self.sessionViewportSpace).islandScrollViewport()
                    .frame(height: viewportHeight).frame(height: availableRowsHeight, alignment: .top)
            }
            HStack(spacing: 7) {
                Text(store.lastRefresh.map { "更新于 " + DisplayTime.clock($0) } ?? "加载中…")
                    .font(Theme.font(9)).foregroundStyle(Theme.tertiary)
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    Circle().fill(healthColor(agent)).frame(width: 5, height: 5).help(healthHelp(agent))
                }
                Spacer()
                Button(action: refresh) {
                    if store.isRefreshing && animated && animationsVisible {
                        LayerAnimationView(kind: .refresh, color: Theme.secondary, running: true).frame(width: 24, height: 24)
                    } else { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                }.disabled(store.isRefreshing).help("刷新").islandInteraction(.control("refresh"))
                Button(action: settings) { Image(systemName: "gearshape").frame(width: 24, height: 24) }.help("设置").islandInteraction(.control("settings"))
            }.font(.system(size: 11)).foregroundStyle(Theme.secondary).buttonStyle(.plain)
                .frame(height: 24).padding(.top, 8)
        }.padding(.horizontal, 16).padding(.bottom, 12).frame(height: availableHeight)
    }
    private static let sessionViewportSpace = "sessionViewport"

    private var sessionHeader: some View {
        ZStack(alignment: .trailing) {
            if columns == 2 {
                HStack(spacing: SessionListLayout.columnSpacing) {
                    ForEach(Array(zip([AgentKind.claude, .codex], sessionColumns)), id: \.0) { agent, sessions in
                        HStack(spacing: 5) {
                            Text(agent.displayName).foregroundStyle(Theme.secondary)
                            Text("· \(sessions.filter { $0.phase != .ended }.count)").foregroundStyle(Theme.tertiary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(spacing: 5) {
                    Text("会话").foregroundStyle(Theme.secondary)
                    Text("· \(store.sessions.filter { $0.phase != .ended }.count) 个活跃").foregroundStyle(Theme.tertiary)
                    Spacer()
                }
            }
            HStack(spacing: 5) {
                if !store.sessionWarnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        .help(store.sessionWarnings.values.sorted().joined(separator: "\n"))
                }
                if store.anyWorking {
                    Circle().fill(Color.green).frame(width: 4, height: 4)
                    Text("正在工作").foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private var sessionRows: some View {
        HStack(alignment: .top, spacing: SessionListLayout.columnSpacing) {
            ForEach(sessionColumns.indices, id: \.self) { index in
                sessionColumn(sessionColumns[index], index: index)
            }
        }.frame(height: documentHeight, alignment: .top)
    }

    private func sessionColumn(_ sessions: [AgentSession], index: Int) -> some View {
        let heights = columnRowHeights[index]
        let bottoms = heights.reduce(into: [CGFloat]()) { $0.append(($0.last ?? 0) + $1) }
        return GeometryReader { proxy in
            // Resolve against the shared viewport on every scroll geometry update; no timer.
            let bottom = viewportHeight - proxy.frame(in: .named(Self.sessionViewportSpace)).minY
            let fullHeight = sessions.isEmpty ? SessionListLayout.rowHeight
                : SessionListLayout.viewportHeight(rowHeights: heights, available: bottom)
            let canvas = proxy.frame(in: .named(IslandInteractionGeometry.coordinateSpace))
            let visible = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: fullHeight)
            let top = -proxy.frame(in: .named(Self.sessionViewportSpace)).minY
            let visibleRows = sessions.indices.filter { bottoms[$0] > top && bottoms[$0] <= fullHeight }
            let firstTop = visibleRows.first.map { bottoms[$0] - heights[$0] } ?? 0
            let lastBottom = visibleRows.last.map { bottoms[$0] } ?? 0
            VStack(spacing: 0) {
                if sessions.isEmpty {
                    Text("暂无 \(index == 0 ? "Claude" : "Codex") 会话")
                        .font(Theme.font(11)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: SessionListLayout.rowHeight)
                } else {
                    Color.clear.frame(height: firstTop).allowsHitTesting(false)
                    ForEach(visibleRows.map { sessions[$0] }) { session in
                        SessionRow(session: session, now: now, animated: animated && animationsVisible,
                                   expanded: store.expandedSessionIDs.contains(session.id)) {
                            if !store.expandedSessionIDs.insert(session.id).inserted { store.expandedSessionIDs.remove(session.id) }
                        }
                    }
                    Color.clear.frame(height: (bottoms.last ?? 0) - lastBottom).allowsHitTesting(false)
                }
            }
            // Fixed spacers preserve independent document heights. Only visible,
            // complete-bottom rows create views or interaction regions; native lazy
            // stacks can oscillate their height estimates when the columns disagree.
            .transformPreference(IslandInteractionPreference.self) { regions in
                for index in regions.indices { regions[index].rect = regions[index].rect.intersection(visible) }
            }
        }.frame(maxWidth: .infinity).frame(height: max(44, heights.reduce(0, +)))
    }
    private func healthColor(_ agent: AgentKind) -> Color {
        switch store.health[agent] {
        case .ok: .green
        case .failed: Theme.critical
        default: Theme.tertiary
        }
    }
    private func healthHelp(_ agent: AgentKind) -> String {
        let snapshot = store.quotas[agent]
        return "\(agent.displayName) · \(snapshot?.source.label ?? "等待数据")\n最近成功：\(snapshot.map { DisplayTime.full($0.fetchedAt) } ?? "暂无")"
    }
}
