import AppKit
import SwiftUI
import IslandCore

enum IslandMotionDirection: Equatable, Sendable {
    case expand
    case collapse
    case resizeExpanded
    case immediate
}

struct IslandMotionPresentation: Equatable, Sendable {
    var mode: IslandMode
    var size: CGSize
}

enum IslandCanvasHoldKind: Equatable, Sendable {
    case collapsing
    case resizingExpanded
}

struct IslandCanvasHold: Equatable, Sendable {
    var until: TimeInterval
    var kind: IslandCanvasHoldKind
}

struct IslandCanvasDecision: Equatable, Sendable {
    var canvas: CGSize
    var hold: IslandCanvasHold?

    var settleAt: TimeInterval? { hold?.until }
}

enum IslandMotion {
    static let expandResponse: TimeInterval = 0.34
    static let expandDamping = 0.72
    static let expandSettlingDuration: TimeInterval = 0.360
    static let collapseResponse: TimeInterval = 0.28
    static let collapseDamping = 1.0
    static let collapseSettlingDuration: TimeInterval = 0.295
    static let resizeResponse: TimeInterval = 0.42
    static let resizeDamping = 0.80
    static let contentAppearDuration: TimeInterval = 0.22
    static let contentAppearDelay: TimeInterval = 0.07
    static let contentDisappearDuration: TimeInterval = 0.10
    static let reduceMotionDuration: TimeInterval = 0.15
    static let canvasSafetyInterval: TimeInterval = 0.060
    static let canvasVerticalShadowPadding: CGFloat = 36

    static var collapseCanvasDelay: TimeInterval { collapseSettlingDuration + canvasSafetyInterval }
    static var resizeCanvasDelay: TimeInterval { expandSettlingDuration + canvasSafetyInterval }

    static func direction(from old: IslandMotionPresentation, to new: IslandMotionPresentation) -> IslandMotionDirection {
        if old.mode != .expanded, new.mode == .expanded { return .expand }
        if old.mode == .expanded, new.mode != .expanded { return .collapse }
        if old.mode == .expanded, new.mode == .expanded, old.size != new.size { return .resizeExpanded }
        return .immediate
    }

    static func shapeAnimation(for direction: IslandMotionDirection, reduceMotion: Bool) -> Animation? {
        guard direction != .immediate else { return nil }
        if reduceMotion { return .easeInOut(duration: reduceMotionDuration) }
        switch direction {
        case .expand: return .spring(response: expandResponse, dampingFraction: expandDamping)
        case .collapse: return .spring(response: collapseResponse, dampingFraction: collapseDamping)
        case .resizeExpanded: return .spring(response: resizeResponse, dampingFraction: resizeDamping)
        case .immediate: return nil
        }
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        let insertion = AnyTransition.modifier(
            active: IslandContentEffect(progress: 0), identity: IslandContentEffect(progress: 1)
        )
        return .asymmetric(insertion: insertion, removal: .opacity)
    }

    static func contentAnimation(appearing: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: reduceMotionDuration) }
        return appearing
            ? .easeOut(duration: contentAppearDuration).delay(contentAppearDelay)
            : .easeIn(duration: contentDisappearDuration)
    }

    static func targetCanvas(shape: CGSize, mode: IslandMode, fixedWidth: CGFloat) -> CGSize {
        CGSize(width: fixedWidth,
               height: shape.height + (mode == .expanded ? canvasVerticalShadowPadding : 0))
    }

    /// Chooses the backing canvas independently from SwiftUI's shape animation.
    /// Shrinks are deferred, while growth and a rapid reopen take effect immediately.
    static func canvasDecision(oldMode: IslandMode, newMode: IslandMode,
                               currentCanvas: CGSize, targetCanvas: CGSize,
                               hold: IslandCanvasHold?, now: TimeInterval,
                               settled: Bool = false) -> IslandCanvasDecision {
        guard !settled else { return IslandCanvasDecision(canvas: targetCanvas, hold: nil) }

        let shrinking = currentCanvas.height > targetCanvas.height
        let containsTarget = currentCanvas.width >= targetCanvas.width && currentCanvas.height >= targetCanvas.height
        if let hold {
            let directionStillApplies = switch hold.kind {
            case .collapsing: newMode != .expanded
            case .resizingExpanded: newMode == .expanded
            }
            if directionStillApplies {
                guard hold.until > now, shrinking, containsTarget else {
                    return IslandCanvasDecision(canvas: targetCanvas, hold: nil)
                }
                return IslandCanvasDecision(
                    canvas: CGSize(width: targetCanvas.width, height: currentCanvas.height), hold: hold
                )
            }
            // Reopening during a collapse always clears the old hold immediately.
            if hold.kind == .collapsing {
                return IslandCanvasDecision(canvas: targetCanvas, hold: nil)
            }
        }

        if oldMode == .expanded, newMode == .expanded, shrinking {
            let hold = IslandCanvasHold(until: now + resizeCanvasDelay, kind: .resizingExpanded)
            return IslandCanvasDecision(
                canvas: CGSize(width: targetCanvas.width, height: currentCanvas.height), hold: hold
            )
        }
        if oldMode == .expanded, newMode != .expanded, shrinking {
            let hold = IslandCanvasHold(until: now + collapseCanvasDelay, kind: .collapsing)
            return IslandCanvasDecision(
                canvas: CGSize(width: targetCanvas.width, height: currentCanvas.height), hold: hold
            )
        }
        return IslandCanvasDecision(canvas: targetCanvas, hold: nil)
    }
}

private struct IslandContentEffect: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.94 + 0.06 * progress, anchor: .top)
            .blur(radius: 6 * (1 - progress))
    }
}
