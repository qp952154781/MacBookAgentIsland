import Foundation
import Testing
import IslandCore
@testable import AgentIsland

@Test func islandMotionSelectsOneDirectionForEachPresentationChange() {
    let collapsed = IslandMotionPresentation(mode: .collapsed, size: CGSize(width: 183, height: 31))
    let active = IslandMotionPresentation(mode: .active, size: CGSize(width: 183, height: 31))
    let expanded = IslandMotionPresentation(mode: .expanded, size: CGSize(width: 760, height: 360))
    let taller = IslandMotionPresentation(mode: .expanded, size: CGSize(width: 760, height: 400))
    #expect(IslandMotion.direction(from: collapsed, to: expanded) == .expand)
    #expect(IslandMotion.direction(from: expanded, to: active) == .collapse)
    #expect(IslandMotion.direction(from: expanded, to: taller) == .resizeExpanded)
    #expect(IslandMotion.direction(from: collapsed, to: active) == .immediate)
}

@Test func repeatedCollapseCallsRetainTheOriginalDeadlineUntilSettled() throws {
    let expanded = CGSize(width: 808, height: 436)
    let collapsed = CGSize(width: 808, height: 31)
    let collapse = IslandMotion.canvasDecision(oldMode: .expanded, newMode: .collapsed,
        currentCanvas: expanded, targetCanvas: collapsed, hold: nil, now: 10)
    #expect(collapse.canvas == expanded)
    #expect(try #require(collapse.settleAt) == 10 + IslandMotion.collapseCanvasDelay)

    let repeated = IslandMotion.canvasDecision(oldMode: .collapsed, newMode: .collapsed,
        currentCanvas: collapse.canvas, targetCanvas: collapsed, hold: collapse.hold, now: 10.01)
    #expect(repeated.canvas == expanded)
    #expect(repeated.hold == collapse.hold)

    let settled = IslandMotion.canvasDecision(oldMode: .collapsed, newMode: .collapsed,
        currentCanvas: repeated.canvas, targetCanvas: collapsed, hold: repeated.hold,
        now: try #require(repeated.settleAt), settled: true)
    #expect(settled.canvas == collapsed)
    #expect(settled.hold == nil)
}

@Test func rapidReopenClearsCollapseHoldAndUsesExpandedTarget() throws {
    let expanded = CGSize(width: 808, height: 436)
    let collapsed = CGSize(width: 808, height: 31)
    let collapse = IslandMotion.canvasDecision(oldMode: .expanded, newMode: .collapsed,
        currentCanvas: expanded, targetCanvas: collapsed, hold: nil, now: 10)
    let reopen = IslandMotion.canvasDecision(oldMode: .collapsed, newMode: .expanded,
        currentCanvas: collapse.canvas, targetCanvas: expanded, hold: collapse.hold, now: 10.1)
    #expect(reopen.canvas == expanded)
    #expect(reopen.hold == nil)
}

@Test func repeatedExpandedResizeRetainsTheOriginalDeadlineUntilSettled() throws {
    let expanded = CGSize(width: 808, height: 436)
    let shorter = CGSize(width: 808, height: 400)
    let resize = IslandMotion.canvasDecision(oldMode: .expanded, newMode: .expanded,
        currentCanvas: expanded, targetCanvas: shorter, hold: nil, now: 20)
    #expect(resize.canvas == expanded)
    #expect(try #require(resize.settleAt) == 20 + IslandMotion.resizeCanvasDelay)

    let repeated = IslandMotion.canvasDecision(oldMode: .expanded, newMode: .expanded,
        currentCanvas: resize.canvas, targetCanvas: shorter, hold: resize.hold, now: 20.01)
    #expect(repeated.canvas == expanded)
    #expect(repeated.hold == resize.hold)

    let settled = IslandMotion.canvasDecision(oldMode: .expanded, newMode: .expanded,
        currentCanvas: repeated.canvas, targetCanvas: shorter, hold: repeated.hold,
        now: try #require(repeated.settleAt), settled: true)
    #expect(settled.canvas == shorter)
    #expect(settled.hold == nil)
}

@Test func canvasWidthIsStableAcrossModesColumnsAndCollapsedStyles() {
    let notched = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 665, height: 32),
        auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32))
    let external = NotchMetrics(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        safeAreaTop: 0, menuBarHeight: 24)

    for notch in [notched, external] {
        var widths: [CGFloat] = []
        for style in CollapsedStyle.allCases {
            for expandedWidth: CGFloat in [IslandLayout.singleColumnWidth, SessionListLayout.twoColumnWidth] {
                var config = IslandLayoutConfig()
                config.collapsedStyle = style
                config.expandedWidth = expandedWidth
                let fixedWidth = IslandLayout.canvasWidth(notch: notch, config: config)
                for mode in IslandMode.allCases {
                    let shape = IslandLayout.size(for: mode, notch: notch, config: config)
                    widths.append(IslandMotion.targetCanvas(shape: shape, mode: mode, fixedWidth: fixedWidth).width)
                }
            }
        }
        #expect(widths.allSatisfy { $0 == widths.first })
        #expect(widths.first == SessionListLayout.twoColumnWidth + IslandLayout.canvasHorizontalPadding)
    }
}
