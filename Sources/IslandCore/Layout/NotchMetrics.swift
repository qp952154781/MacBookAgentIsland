import Foundation

public struct NotchMetrics: Sendable, Equatable {
    public var screenFrame: CGRect
    public var visibleFrame: CGRect
    public var hasNotch: Bool
    public var notchRect: CGRect

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hasNotch == rhs.hasNotch && NSEqualRects(lhs.screenFrame, rhs.screenFrame)
            && NSEqualRects(lhs.visibleFrame, rhs.visibleFrame) && NSEqualRects(lhs.notchRect, rhs.notchRect)
    }

    public init(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect? = nil,
                auxiliaryTopRight: CGRect? = nil, menuBarHeight: CGFloat = 24, visibleFrame: CGRect? = nil) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame ?? screenFrame
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
           NSMinX(right) > NSMaxX(left) {
            hasNotch = true
            notchRect = NSMakeRect(NSMaxX(left), NSMaxY(screenFrame) - safeAreaTop,
                               NSMinX(right) - NSMaxX(left), safeAreaTop)
        } else {
            hasNotch = false
            notchRect = NSMakeRect(NSMidX(screenFrame), NSMaxY(screenFrame) - max(0, menuBarHeight),
                               0, max(0, menuBarHeight))
        }
    }
}
