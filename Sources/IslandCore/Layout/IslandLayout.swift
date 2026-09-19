import Foundation

public enum IslandMode: String, Sendable, CaseIterable { case collapsed, active, expanded }

public enum CollapsedStyle: String, Sendable, CaseIterable {
    case hidden, wings

    public var label: String {
        switch self {
        case .hidden: "藏进刘海"
        case .wings: "显示两翼"
        }
    }
}

public struct IslandLayoutConfig: Sendable, Equatable {
    public var collapsedStyle: CollapsedStyle = .hidden
    public var wingWidth: CGFloat = 76
    public var expandedWidth: CGFloat = 600
    public var expandedMinHeight: CGFloat = 200
    public var expandedMaxHeight: CGFloat = 400
    public var collapsedBottomRadius: CGFloat = 12
    public var expandedBottomRadius: CGFloat = 28
    public var earRadius: CGFloat = 6
    public var notchSafetyInset: CGFloat = 6
    public init() {}
}

public enum IslandLayout {
    /// Keeps the hidden software shape strictly inside the physical notch outline.
    public static let hiddenNotchInset: CGFloat = 1
    /// Click and hover target used on displays without a hardware notch.
    public static let virtualNotchWidth: CGFloat = 185
    /// Shared outer alignment for quota cards and the expanded system metrics band.
    public static let expandedContentInset: CGFloat = 16
    /// Collapsed wings narrower than this use compact typography and a tighter outer margin.
    public static let compactWingThreshold: CGFloat = 56
    /// The previous lower bound; wings whose content carries labels (single provider,
    /// system monitor, session counts) never go below it so nothing is clipped.
    public static let labeledWingMinimum: CGFloat = 60
    /// Narrowest wing that still shows a brand glyph next to "100%" in compact typography.
    public static let minimumWingWidth: CGFloat = 50
    /// Outer margin of compact wings. The notch side always keeps `notchSafetyInset`.
    public static let compactOuterInset: CGFloat = 3
    /// The expanded island's default one-column width.
    public static let singleColumnWidth: CGFloat = 600
    /// Horizontal room reserved for the expanded shadow around the island.
    public static let canvasHorizontalPadding: CGFloat = 48

    /// Keep the notch anchor even when a side Dock makes the visible frame asymmetric.
    public static func maximumCenteredWidth(notch: NotchMetrics) -> CGFloat {
        let visible = NSIntersectionRect(notch.visibleFrame, notch.screenFrame)
        return max(0, 2 * min(NSMidX(notch.notchRect) - NSMinX(visible) - 24,
                             NSMaxX(visible) - NSMidX(notch.notchRect) - 24))
    }

    /// A screen-stable backing width keeps every island shape centered while it animates.
    public static func canvasWidth(notch: NotchMetrics, config: IslandLayoutConfig = .init()) -> CGFloat {
        let collapsedWidth = size(for: .collapsed, notch: notch, config: config).width
        let maximumShapeWidth = max(SessionListLayout.twoColumnWidth,
                                    max(singleColumnWidth, collapsedWidth))
        return min(maximumShapeWidth, maximumCenteredWidth(notch: notch)) + canvasHorizontalPadding
    }

    public static func size(for mode: IslandMode, notch: NotchMetrics, config: IslandLayoutConfig = .init(),
                            expandedContentHeight: CGFloat = 400) -> CGSize {
        let wings = NSMakeSize(NSWidth(notch.notchRect) + 2 * config.wingWidth, NSHeight(notch.notchRect))
        let hidden = notch.hasNotch
            ? NSMakeSize(max(0, NSWidth(notch.notchRect) - 2 * hiddenNotchInset),
                         max(0, NSHeight(notch.notchRect) - hiddenNotchInset))
            : NSMakeSize(virtualNotchWidth, NSHeight(notch.notchRect))
        let collapsed = config.collapsedStyle == .hidden ? hidden : wings
        switch mode {
        case .collapsed, .active: return collapsed
        case .expanded:
            return NSMakeSize(min(max(wings.width, config.expandedWidth), maximumCenteredWidth(notch: notch)),
                          min(config.expandedMaxHeight, max(config.expandedMinHeight, expandedContentHeight)))
        }
    }

    public static func frame(for mode: IslandMode, notch: NotchMetrics, config: IslandLayoutConfig = .init(),
                             expandedContentHeight: CGFloat = 400) -> CGRect {
        let size = size(for: mode, notch: notch, config: config, expandedContentHeight: expandedContentHeight)
        return NSMakeRect(NSMidX(notch.notchRect) - size.width / 2, NSMaxY(notch.screenFrame) - size.height,
                      size.width, size.height)
    }

    public static func expandedWingRects(notch: NotchMetrics, config: IslandLayoutConfig = .init()) -> (left: CGRect, right: CGRect) {
        var expanded = config
        expanded.wingWidth = (size(for: .expanded, notch: notch, config: config).width - NSWidth(notch.notchRect)) / 2
        return wingRects(notch: notch, config: expanded)
    }

    /// Screen coordinates, anchored next to the notch in every mode for visual continuity.
    public static func wingRects(notch: NotchMetrics, config: IslandLayoutConfig = .init()) -> (left: CGRect, right: CGRect) {
        let rect = notch.notchRect
        let inner = notch.hasNotch ? config.notchSafetyInset : 0
        // Compact wings reclaim part of the outer margin; the notch side stays at the safety inset.
        let outer = config.wingWidth < compactWingThreshold ? min(inner, compactOuterInset) : inner
        let width = max(0, config.wingWidth - inner - outer)
        return (NSMakeRect(NSMinX(rect) - config.wingWidth + outer, NSMinY(rect), width, NSHeight(rect)),
                NSMakeRect(NSMaxX(rect) + inner, NSMinY(rect), width, NSHeight(rect)))
    }
}
