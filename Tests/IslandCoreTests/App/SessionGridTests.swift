import AppKit
import SwiftUI
import Testing
import IslandCore
@testable import AgentIsland

@MainActor @Test func dumpUsesTheSameDisplayOrderAsTheStoreWithoutChangingProviderOrder() {
    let input = SnapshotExporter.sessionGridFixtures(count: 12)
    let store = IslandStore()
    store.sessions = input
    #expect(store.sessions == input)
    #expect(DumpSessions.displaySessions(input).map(\.id) == store.displaySessions.map(\.id))
    store.sessions[0].phase = .runningTool
    #expect(store.displaySessions == SessionDisplayOrder.sorted(store.sessions))
}

@MainActor @Test func gridPanelHeightUsesActualRows() {
    let store = IslandStore.mock(.idle)
    let notch = SnapshotExporter.metrics(hasNotch: true)
    store.sessions = []
    #expect(store.layoutConfig(notch: notch).expandedWidth == 600)
    // Four sessions split two per agent: two grid rows, one row (44 pt) shorter than five sessions.
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 4)
    #expect(store.layoutConfig(notch: notch).expandedWidth == 900)
    #expect(ExpandedView.contentHeight(store: store, notch: notch) == 338)
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 5)
    #expect(store.layoutConfig(notch: notch).expandedWidth == 900)
    #expect(ExpandedView.contentHeight(store: store, notch: notch) == 382)
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 2)
    store.sessionListLayout = .twoColumns
    #expect(ExpandedView.contentHeight(store: store, notch: notch) == 294)
}

@MainActor @Test func hoverRegionTracksAutomaticAndForcedColumnWidthChanges() {
    _ = NSApplication.shared
    let store = IslandStore.mock(.idle)
    let model = IslandViewModel(store: store, forcedState: .expanded)
    let notch = SnapshotExporter.metrics(hasNotch: true)
    let panel = NotchPanel(frame: .zero)
    defer { model.stop(); panel.close() }
    let tracker = HoverTracker(panel: panel, model: model, notch: notch)
    let outerCell = CGPoint(x: notch.notchRect.midX + 400, y: notch.screenFrame.maxY - 220)
    store.sessions = []
    tracker.refreshGeometry()
    #expect(!tracker.contains(outerCell))
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 1)
    tracker.refreshGeometry()
    #expect(tracker.contains(outerCell))
    store.sessionListLayout = .singleColumn
    tracker.refreshGeometry()
    #expect(!tracker.contains(outerCell))
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 2)
    store.sessionListLayout = .twoColumns
    tracker.refreshGeometry()
    #expect(tracker.contains(outerCell))
}

@MainActor @Test func recoveryAndExtraQuotaWindowsStillFitOneCompleteExpandedGridRow() {
    let store = IslandStore.mock(.idle)
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 12)
    store.expandedSessionIDs = Set(store.displaySessions.prefix(1).map(\.id))
    store.quotas[.claude]?.windows.append(QuotaWindow(id: "extra", kind: .weeklyModel, label: "额外窗口", usedPercent: 30))
    store.quotas[.codex]?.windows.removeAll { $0.kind == .session }
    var status = ClaudeConnectionStatus()
    status.isRecovering = true
    store.claudeConnection = status
    let notch = SnapshotExporter.metrics(hasNotch: true)
    let config = ExpandedView.layoutConfig(store: store, notch: notch)
    let size = IslandLayout.size(for: .expanded, notch: notch, config: config,
                                 expandedContentHeight: ExpandedView.contentHeight(store: store, notch: notch))
    let rows = size.height - notch.notchRect.height - ExpandedView.overhead(store: store)
    #expect(rows >= 108)
    #expect(SessionListLayout.viewportHeight(columnRowHeights: [[108, 44], [44, 44]], available: rows) >= 108)
}

@MainActor @Test func agentColumnsHaveIndependentRowsAndDetails() async throws {
    _ = NSApplication.shared
    let store = IslandStore.mock(.idle)
    store.sessions = SnapshotExporter.sessionGridFixtures(count: 5)
    let notch = SnapshotExporter.metrics(hasNotch: true)
    let host = IslandHostingView(rootView: IslandRootView(store: store, notch: notch, mode: .expanded,
                                                         now: SnapshotExporter.now, animated: false))
    host.frame = CGRect(x: 0, y: 0, width: 948, height: 436)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
    }
    func cell(_ column: Int, _ index: Int) throws -> CGRect {
        let id = "session:" + store.displaySessionColumns[column][index].id
        return try #require(host.interactionGeometry.regions.first { $0.kind == .control(id) }?.rect)
    }
    try await settle()
    let left = try cell(0, 0), right = try cell(1, 0), second = try cell(1, 1)
    #expect(left.minY == right.minY && right.minX > left.maxX)
    #expect(second.minX == right.minX && second.minY == right.maxY)
    #expect(left.height == 44 && right.height == 44)
    store.expandedSessionIDs = [store.displaySessionColumns[0][0].id]
    try await settle()
    let expanded = try cell(0, 0), neighbor = try cell(1, 0)
    #expect(try cell(1, 1) == second)
    #expect(expanded.height == 108 && neighbor.height == 44)
    #expect(expanded.minY == neighbor.minY && expanded.width == neighbor.width)
    #expect(store.expandedSessionIDs.count == 1)
}

@MainActor @Test func dumpEncodesAgentColumnsAndPreservesTheSingleColumnArray() throws {
    let store = IslandStore()
    store.sessions = SnapshotExporter.agentColumnFixtures(claude: 2, codex: 10)
    store.sessions[0].lastPrompt = String(repeating: "样", count: 100)
    for count in [1, 2] {
        let payload = DumpSessions.displayPayload(store.sessions, columns: count)
        let data = try JSONEncoder().encode(payload)
        let groups: [[AgentSession]]
        if count == 2 {
            let decoded = try JSONDecoder().decode([String: [AgentSession]].self, from: data)
            #expect(Set(decoded.keys) == ["claude", "codex"])
            groups = [decoded["claude"] ?? [], decoded["codex"] ?? []]
        } else {
            groups = [try JSONDecoder().decode([AgentSession].self, from: data)]
        }
        #expect(groups.map { $0.map(\.id) } == store.sessionColumns(count: count).map { $0.map(\.id) })
        #expect(groups.flatMap { $0 }.allSatisfy { ($0.lastPrompt?.count ?? 0) <= 80 })
    }
    for agent in ProviderRegistry.orderedIDs {
        let input = store.sessions.filter { $0.agent == agent }
        let data = try JSONEncoder().encode(DumpSessions.displayPayload(input, columns: 2))
        let decoded = try JSONDecoder().decode([String: [AgentSession]].self, from: data)
        #expect(decoded[agent == .claude ? "codex" : "claude"]?.isEmpty == true)
    }
}

@MainActor @Test func storeCachesIndependentColumnSortsAndKeepsMergedSortForSingleColumn() {
    let store = IslandStore()
    store.sessions = SnapshotExporter.agentColumnFixtures(claude: 4, codex: 7)
    let providerOrder = store.sessions
    #expect(store.sessionColumns(count: 1) == [SessionDisplayOrder.sorted(providerOrder)])
    #expect(store.sessionColumns(count: 2) == SessionDisplayOrder.columns(providerOrder))
    #expect(store.sessions == providerOrder)
    store.sessions[0].agent = .claude
    store.sessions[0].lastActivityAt = .distantFuture
    #expect(store.sessionColumns(count: 2) == SessionDisplayOrder.columns(store.sessions))
    store.sessions = []
    #expect(store.sessionColumns(count: 2) == [[], []])
}

@MainActor @Test(arguments: [true, false])
func agentColumnSharedScrollKeepsCompleteBottomRowsAndReachesTail(hasNotch: Bool) async throws {
    _ = NSApplication.shared
    let store = IslandStore.mock(.idle)
    store.sessions = SnapshotExporter.agentColumnFixtures(claude: 5, codex: 10)
    #expect(Set(store.sessions.map(\.id)).count == 15)
    store.expandedSessionIDs = [store.displaySessionColumns[0][0].id, store.displaySessionColumns[1][1].id]
    let notch = SnapshotExporter.metrics(hasNotch: hasNotch)
    let host = IslandHostingView(rootView: IslandRootView(store: store, notch: notch, mode: .expanded,
        now: SnapshotExporter.now, animationsVisible: false).transaction { $0.disablesAnimations = true })
    host.frame = CGRect(x: 0, y: 0, width: 948, height: 436)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func settle() async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    try await settle()
    let scrolls = scrollViews(host)
    #expect(scrolls.count == 1)
    let scroll = try #require(scrolls.first)
    let document = try #require(scroll.documentView)
    #expect(abs(document.frame.height - (10 * 44 + 64)) < 1)
    let end = document.frame.height - scroll.contentView.bounds.height
    for offset in [CGFloat(0), 17, 44, 108, end] {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let viewport = try #require(host.interactionGeometry.regions.first { $0.kind == .scroll }?.rect)
        let visible = host.interactionGeometry.regions.filter {
            if case let .control(id) = $0.kind { return id.hasPrefix("session:") && !$0.rect.isNull && $0.rect.height > 0 }
            return false
        }
        #expect(!visible.isEmpty)
        for region in visible {
            guard case let .control(id) = region.kind else { continue }
            #expect(region.rect.maxY <= viewport.maxY + 0.5)
            let sessionID = String(id.dropFirst("session:".count))
            if region.rect.minY > viewport.minY + 0.5 {
                let expected: CGFloat = store.expandedSessionIDs.contains(sessionID) ? 108 : 44
                #expect(abs(region.rect.height - expected) < 0.5)
            }
        }
        for (column, sessions) in store.displaySessionColumns.enumerated() {
            var rowBottom: CGFloat = 0
            var lastVisibleBottom = viewport.minY
            for session in sessions {
                rowBottom += store.expandedSessionIDs.contains(session.id) ? 108 : 44
                let screenBottom = viewport.minY + rowBottom - offset
                if screenBottom > viewport.maxY + 0.5 {
                    #expect(!visible.contains { $0.kind == .control("session:" + session.id) })
                } else {
                    lastVisibleBottom = max(lastVisibleBottom, screenBottom)
                }
            }
            if lastVisibleBottom < viewport.maxY - 1 {
                let width = (viewport.width - SessionListLayout.columnSpacing) / 2
                let blank = CGPoint(x: viewport.minX + CGFloat(column) * (width + SessionListLayout.columnSpacing) + width / 2,
                                    y: (lastVisibleBottom + viewport.maxY) / 2)
                #expect(!host.interactionGeometry.isControl(blank))
            }
        }
        if offset == end, let last = store.displaySessionColumns[1].last {
            #expect(visible.contains { $0.kind == .control("session:" + last.id) && abs($0.rect.height - 44) < 0.5 })
        }
    }
}
