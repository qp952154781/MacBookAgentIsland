import Foundation
import Testing
@testable import IslandCore

private func gridMetrics(width: CGFloat = 1512, visibleWidth: CGFloat? = nil) -> NotchMetrics {
    let visible = visibleWidth.map { CGRect(x: (width - $0) / 2, y: 0, width: $0, height: 900) }
    return NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: width, height: 982), safeAreaTop: 0,
                        visibleFrame: visible)
}

@Test func sessionColumnsAndWidthFollowCountPreferenceAndScreen() {
    let notch = gridMetrics()
    // Automatic separates Claude and Codex as soon as there is one active session;
    // with none, a single empty-state row is shown instead of two placeholders.
    let none = SessionListLayout(mode: .automatic, activeCount: 0, notch: notch)
    #expect(none.columns == 1 && none.width == 600)
    for count in [1, 2, 4, 5, 12] {
        let layout = SessionListLayout(mode: .automatic, activeCount: count, notch: notch)
        #expect(layout.columns == 2 && layout.width == SessionListLayout.twoColumnWidth)
    }
    #expect(SessionListLayout(mode: .singleColumn, activeCount: 12, notch: notch).columns == 1)
    for count in [0, 1, 2] {
        #expect(SessionListLayout(mode: .twoColumns, activeCount: count, notch: notch).columns == 2)
    }
    for mode in SessionListLayoutMode.allCases {
        let narrow = SessionListLayout(mode: mode, activeCount: 12, notch: gridMetrics(visibleWidth: 807))
        #expect(narrow.columns == 1 && narrow.width == 600)
    }
    let minimum = SessionListLayout(mode: .twoColumns, activeCount: 2, notch: gridMetrics(visibleWidth: 808))
    #expect(minimum.columns == 2 && minimum.width == 760)
    #expect(SessionListLayout(mode: .automatic, activeCount: 12, notch: gridMetrics(width: 600)).width == 552)
}

@Test func centeredPanelRespectsVisibleFrameIncludingSideDockAndScreenOffsets() {
    for hasNotch in [false, true] {
        let screen = CGRect(x: -1800, y: 200, width: 1512, height: 982)
        let notch = NotchMetrics(screenFrame: screen, safeAreaTop: hasNotch ? 32 : 0,
            auxiliaryTopLeft: CGRect(x: -1800, y: 1150, width: 664, height: 32),
            auxiliaryTopRight: CGRect(x: -952, y: 1150, width: 664, height: 32),
            visibleFrame: CGRect(x: -1520, y: 200, width: 1232, height: 950))
        let layout = SessionListLayout(mode: .twoColumns, activeCount: 12, notch: notch)
        var config = IslandLayoutConfig()
        config.expandedWidth = layout.width
        let frame = IslandLayout.frame(for: .expanded, notch: notch, config: config)
        #expect(frame.midX == notch.notchRect.midX)
        #expect(frame.minX >= notch.visibleFrame.minX + 24)
        #expect(frame.maxX <= notch.visibleFrame.maxX - 24)
        #expect(frame.width <= notch.visibleFrame.width - 48)
    }
}

@Test func independentColumnHeightsAndViewportKeepWholeRows() {
    let claude = (0..<2).map { AgentSession(agent: .claude, sessionId: "\($0)", title: "样例", lastActivityAt: .distantPast) }
    let codex = (0..<10).map { AgentSession(agent: .codex, sessionId: "\($0)", title: "样例", lastActivityAt: .distantPast) }
    let right = SessionListLayout.rowHeights(sessions: codex, expandedIDs: [])
    let expanded: Set<String> = [claude[0].id]
    let left = SessionListLayout.rowHeights(sessions: claude, expandedIDs: expanded)
    #expect(left == [108, 44])
    #expect(right == Array(repeating: 44, count: 10))
    #expect(SessionListLayout.rowHeights(sessions: codex, expandedIDs: expanded) == right)
    #expect(SessionListLayout.viewportHeight(columnRowHeights: [left, right], available: 150) == 132)
    #expect(SessionListLayout.viewportHeight(rowHeights: left, available: 132) == 108)
    #expect(SessionListLayout.viewportHeight(rowHeights: right, available: 132) == 132)
    #expect(SessionListLayout.viewportHeight(rowHeights: [108], available: 100) == 0)
}

@Test func unequalAndExpandedColumnBottomsAlwaysEndAtTheLargestCompletePrefix() {
    let combinations: [[[CGFloat]]] = [
        [[44, 44], Array(repeating: 44, count: 10)], [[], [44, 44, 44]], [[108, 44], []], [[], []],
        [[108, 44, 44], [44, 44, 44, 44]], [[108, 44, 44], [108, 44, 44, 44]],
        [[44, 108, 44], [108, 44, 44, 44, 44]], [[108], [44, 108, 44]]
    ]
    for columns in combinations {
        for available in stride(from: CGFloat(0), through: 400, by: 1) {
            let viewport = SessionListLayout.viewportHeight(columnRowHeights: columns, available: available)
            #expect(viewport <= available)
            for rows in columns {
                // Exercise the same document-relative cutoff at initial and scrolled positions.
                for offset: CGFloat in [0, 17, 44, 108, 190] {
                    let bottom = viewport + offset
                    let complete = SessionListLayout.viewportHeight(rowHeights: rows, available: bottom)
                    var boundaries: [CGFloat] = [0]
                    for row in rows { boundaries.append((boundaries.last ?? 0) + row) }
                    #expect(boundaries.contains(complete))
                    #expect(complete == boundaries.filter { $0 <= bottom }.max())
                }
            }
        }
    }
}

@MainActor @Test func automaticCountsNonEndedSessionsAndSettingsApplyImmediately() {
    let store = IslandStore()
    store.sessions = [AgentSession(agent: .codex, sessionId: "0", title: "样例", phase: .idle, lastActivityAt: .distantPast)]
    #expect(store.sessionLayout(notch: gridMetrics()).columns == 2)
    // An ended session is not active: with nothing left to show, the empty state is a single row.
    store.sessions[0].phase = .ended
    #expect(store.sessionLayout(notch: gridMetrics()).columns == 1)
    let settings = AppSettings()
    #expect(settings.sessionListLayout == .automatic)
    settings.onChange = { settings.apply(to: store) }
    settings.sessionListLayout = .twoColumns
    #expect(store.sessionLayout(notch: gridMetrics()).columns == 2)
    settings.sessionListLayout = .singleColumn
    #expect(store.sessionLayout(notch: gridMetrics()).width == 600)
    settings.onChange = nil
}

@MainActor private final class GridSettingsDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey name: String) -> String? { values[name] as? String }
    func object(forKey name: String) -> Any? { values[name] }
    func set(_ value: Any?, forKey name: String) { values[name] = value }
}

@MainActor @Test func sessionLayoutPersistsReloadsAndToleratesUnknownValues() {
    let defaults = GridSettingsDefaults()
    #expect(AppSettings(defaults: defaults).sessionListLayout == .automatic)
    let settings = AppSettings(defaults: defaults)
    for mode in SessionListLayoutMode.allCases {
        settings.sessionListLayout = mode
        #expect(defaults.string(forKey: "sessionListLayout") == mode.rawValue)
        #expect(AppSettings(defaults: defaults).sessionListLayout == mode)
    }
    defaults.values["sessionListLayout"] = "future-layout"
    #expect(AppSettings(defaults: defaults).sessionListLayout == .automatic)
}
