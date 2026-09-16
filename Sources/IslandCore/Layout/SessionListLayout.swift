import Foundation

public enum SessionListLayoutMode: String, CaseIterable, Sendable {
    case automatic, singleColumn, twoColumns

    public var label: String {
        switch self {
        case .automatic: "自动"
        case .singleColumn: "单列"
        case .twoColumns: "双列"
        }
    }
}

public struct SessionListLayout: Equatable, Sendable {
    public static let rowHeight: CGFloat = 44
    public static let detailHeight: CGFloat = 64
    public static let columnSpacing: CGFloat = 16
    public let columns: Int
    public let width: CGFloat

    public init(mode: SessionListLayoutMode, activeCount: Int, notch: NotchMetrics,
                singleColumnWidth: CGFloat = 600) {
        let limit = IslandLayout.maximumCenteredWidth(notch: notch)
        let wantsTwo = mode == .twoColumns || (mode == .automatic && activeCount >= 5)
        columns = wantsTwo && limit >= 880 ? 2 : 1
        width = min(columns == 2 ? 900 : singleColumnWidth, limit)
    }

    public static func rowHeights(sessions: [AgentSession], expandedIDs: Set<String>) -> [CGFloat] {
        sessions.map { rowHeight + (expandedIDs.contains($0.id) ? detailHeight : 0) }
    }

    /// The last complete row boundary at or before the supplied document coordinate.
    /// Zero means even the first row does not fit; never return a partial row.
    public static func viewportHeight(rowHeights: [CGFloat], available: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for row in rowHeights {
            guard height + row <= available else { break }
            height += row
        }
        return height
    }

    /// Independent columns can have incompatible boundaries (e.g. 108 vs 132 pt).
    /// Use the largest complete prefix and end each column at its own last full row.
    /// A short column leaves blank space; it never pads or shifts its following rows.
    public static func viewportHeight(columnRowHeights: [[CGFloat]], available: CGFloat) -> CGFloat {
        columnRowHeights.map { viewportHeight(rowHeights: $0, available: available) }.max() ?? 0
    }
}
