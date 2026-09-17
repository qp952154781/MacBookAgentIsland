import Foundation

public enum IslandMode: String, Sendable, CaseIterable { case collapsed, active, expanded }

public struct IslandLayoutConfig: Sendable, Equatable {
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

    /// Keep the notch anchor even when a side Dock makes the visible frame asymmetric.
    public static func maximumCenteredWidth(notch: NotchMetrics) -> CGFloat {
        let visible = NSIntersectionRect(notch.visibleFrame, notch.screenFrame)
        return max(0, 2 * min(NSMidX(notch.notchRect) - NSMinX(visible) - 24,
                             NSMaxX(visible) - NSMidX(notch.notchRect) - 24))
    }

    public static func size(for mode: IslandMode, notch: NotchMetrics, config: IslandLayoutConfig = .init(),
                            expandedContentHeight: CGFloat = 400) -> CGSize {
        let base = NSMakeSize(NSWidth(notch.notchRect) + 2 * config.wingWidth, NSHeight(notch.notchRect))
        switch mode {
        case .collapsed, .active: return base
        case .expanded:
            return NSMakeSize(min(max(base.width, config.expandedWidth), maximumCenteredWidth(notch: notch)),
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
