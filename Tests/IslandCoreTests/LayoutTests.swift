import Foundation
import Testing
@testable import IslandCore

private func builtIn() -> NotchMetrics {
    NotchMetrics(screenFrame: NSMakeRect(0, 0, 1512, 982), safeAreaTop: 32,
                 auxiliaryTopLeft: NSMakeRect(0, 950, 665, 32), auxiliaryTopRight: NSMakeRect(850, 950, 662, 32))
}

@Test func notchGeometry() {
    let notch = builtIn()
    #expect(notch.hasNotch)
    #expect(NSEqualRects(notch.notchRect, NSMakeRect(665, 950, 185, 32)))
    let external = NotchMetrics(screenFrame: NSMakeRect(-1920, 200, 1920, 1080), safeAreaTop: 0, menuBarHeight: 24)
    #expect(!external.hasNotch)
    #expect(NSEqualRects(external.notchRect, NSMakeRect(-960, 1256, 0, 24)))
    #expect(!NotchMetrics(screenFrame: NSMakeRect(0, 0, 1512, 982), safeAreaTop: 32).hasNotch)
}

@Test func islandFrames() {
    let notch = builtIn()
    let expected: [(IslandMode, CGFloat, CGFloat)] = [(.collapsed, 337, 32), (.active, 337, 32), (.expanded, 600, 400)]
    for (mode, width, height) in expected {
        let size = IslandLayout.size(for: mode, notch: notch)
        #expect(Double(size.width) == Double(width))
        #expect(Double(size.height) == Double(height))
        let frame = IslandLayout.frame(for: mode, notch: notch)
        #expect(NSEqualRects(frame, NSMakeRect(757.5 - width / 2, 982 - height, width, height)))
    }
    #expect(IslandLayout.size(for: .expanded, notch: notch, expandedContentHeight: 100).height == 200)
    #expect(IslandLayout.size(for: .expanded, notch: notch, expandedContentHeight: 500).height == 400)
    let wings = IslandLayout.wingRects(notch: notch)
    #expect(NSEqualRects(wings.left, NSMakeRect(595, 950, 64, 32)))
    #expect(NSEqualRects(wings.right, NSMakeRect(856, 950, 64, 32)))
    for wing in [wings.left, wings.right] {
        #expect(!NSIntersectsRect(wing, notch.notchRect))
        for mode in IslandMode.allCases { #expect(NSContainsRect(IslandLayout.frame(for: mode, notch: notch), wing)) }
    }
}

@Test func externalLayout() {
    let notch = NotchMetrics(screenFrame: NSMakeRect(0, 0, 1920, 1080), safeAreaTop: 0, menuBarHeight: 24)
    #expect(NSEqualRects(IslandLayout.frame(for: .collapsed, notch: notch), NSMakeRect(884, 1056, 152, 24)))
    #expect(IslandLayout.size(for: .active, notch: notch).height == 24)
    let wings = IslandLayout.wingRects(notch: notch)
    #expect(NSMaxX(wings.left) == 960)
    #expect(NSMinX(wings.right) == NSMaxX(wings.left))
    #expect(NSWidth(wings.left) == 76)
    #expect(NSWidth(wings.right) == 76)
    #expect(!NSIntersectsRect(wings.left, wings.right))
}

@Test(arguments: [CGFloat(50), 60, 76, 100])
func activeStaysWithinTopBand(wingWidth: CGFloat) {
    let external = NotchMetrics(screenFrame: NSMakeRect(-1920, 200, 1920, 1080),
                                safeAreaTop: 0, menuBarHeight: 24)
    var config = IslandLayoutConfig()
    config.wingWidth = wingWidth
    for notch in [builtIn(), external] {
        let collapsed = IslandLayout.frame(for: .collapsed, notch: notch, config: config)
        let active = IslandLayout.frame(for: .active, notch: notch, config: config)
        #expect(active == collapsed)
        #expect(active.height == notch.notchRect.height)
        #expect(active.minY == notch.notchRect.minY)
        #expect(active.maxY == notch.screenFrame.maxY)
    }
}

@Test func compactWingsReclaimOnlyTheOuterMargin() {
    let notch = builtIn()
    var config = IslandLayoutConfig()
    // Compact wings: 3 pt outer margin, the notch side keeps its 6 pt safety inset.
    config.wingWidth = IslandLayout.minimumWingWidth
    var wings = IslandLayout.wingRects(notch: notch, config: config)
    #expect(IslandLayout.minimumWingWidth == 50)
    #expect(NSEqualRects(wings.left, NSMakeRect(665 - 50 + 3, 950, 41, 32)))
    #expect(NSEqualRects(wings.right, NSMakeRect(850 + 6, 950, 41, 32)))
    // At and above the threshold the geometry is exactly what it was before compact wings existed.
    for width: CGFloat in [IslandLayout.compactWingThreshold, 60, 76] {
        config.wingWidth = width
        wings = IslandLayout.wingRects(notch: notch, config: config)
        #expect(NSEqualRects(wings.left, NSMakeRect(665 - width + 6, 950, width - 12, 32)))
        #expect(NSEqualRects(wings.right, NSMakeRect(856, 950, width - 12, 32)))
    }
    // Displays without a notch have no insets at any width.
    let external = NotchMetrics(screenFrame: NSMakeRect(-1920, 200, 1920, 1080), safeAreaTop: 0, menuBarHeight: 24)
    config.wingWidth = IslandLayout.minimumWingWidth
    wings = IslandLayout.wingRects(notch: external, config: config)
    #expect(NSWidth(wings.left) == IslandLayout.minimumWingWidth && NSWidth(wings.right) == IslandLayout.minimumWingWidth)
}

