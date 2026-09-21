import Foundation
import SwiftUI
import IslandCore

struct SnapshotAnimationTimeline: Equatable, Sendable {
    var frameRate: Double = 25
    var initialHold: TimeInterval = 0.2
    var expand: TimeInterval = 0.6
    var expandedHold: TimeInterval = 1.4
    var collapse: TimeInterval = 0.5
    var finalHold: TimeInterval = 0.3

    var duration: TimeInterval { initialHold + expand + expandedHold + collapse + finalHold }
    var frameDuration: TimeInterval { 1 / frameRate }
    var frameCount: Int { Int((duration * frameRate).rounded()) }
    var expandStart: TimeInterval { initialHold }
    var expandedHoldStart: TimeInterval { expandStart + expand }
    var collapseStart: TimeInterval { expandedHoldStart + expandedHold }
    var finalHoldStart: TimeInterval { collapseStart + collapse }
}

enum SnapshotAnimationPhase: Equatable, Sendable {
    case initialHold, expand, expandedHold, collapse, finalHold
}

struct SnapshotAnimationFrame: Equatable, Sendable {
    let index: Int
    let time: TimeInterval
    let delay: TimeInterval
    let phase: SnapshotAnimationPhase
    let presentation: IslandMotionPresentation
    let contentProgress: Double
}

enum SnapshotAnimationFramePlan {
    static func make(timeline: SnapshotAnimationTimeline = .init(),
                     collapsedSize: CGSize, expandedSize: CGSize) -> [SnapshotAnimationFrame] {
        guard timeline.frameRate > 0, timeline.duration > 0 else { return [] }
        return (0..<timeline.frameCount).map { index in
            let time = Double(index) * timeline.frameDuration
            let sample = sample(time: time, timeline: timeline)
            return SnapshotAnimationFrame(
                index: index,
                time: time,
                delay: timeline.frameDuration,
                phase: sample.phase,
                presentation: IslandMotionPresentation(
                    mode: sample.mode,
                    size: interpolate(from: collapsedSize, to: expandedSize, progress: sample.shapeProgress)
                ),
                contentProgress: sample.contentProgress
            )
        }
    }

    private static func sample(time: TimeInterval, timeline: SnapshotAnimationTimeline)
        -> (phase: SnapshotAnimationPhase, mode: IslandMode, shapeProgress: Double, contentProgress: Double) {
        if time < timeline.expandStart {
            return (.initialHold, .collapsed, 0, 0)
        }
        if time < timeline.expandedHoldStart {
            let elapsed = time - timeline.expandStart
            let spring = Spring(response: IslandMotion.expandResponse, dampingRatio: IslandMotion.expandDamping)
            let shape = spring.value(target: 1.0, time: elapsed)
            return (.expand, .expanded, shape, appearingContentProgress(at: elapsed))
        }
        if time < timeline.collapseStart {
            return (.expandedHold, .expanded, 1, 1)
        }
        if time < timeline.finalHoldStart {
            let elapsed = time - timeline.collapseStart
            let spring = Spring(response: IslandMotion.collapseResponse, dampingRatio: IslandMotion.collapseDamping)
            let shape = 1 - spring.value(target: 1.0, time: elapsed)
            return (.collapse, .collapsed, shape, disappearingContentProgress(at: elapsed))
        }
        return (.finalHold, .collapsed, 0, 0)
    }

    private static func appearingContentProgress(at elapsed: TimeInterval) -> Double {
        guard elapsed > IslandMotion.contentAppearDelay else { return 0 }
        let linear = min(1, (elapsed - IslandMotion.contentAppearDelay) / IslandMotion.contentAppearDuration)
        return UnitCurve.easeOut.value(at: linear)
    }

    private static func disappearingContentProgress(at elapsed: TimeInterval) -> Double {
        let linear = min(1, max(0, elapsed / IslandMotion.contentDisappearDuration))
        return 1 - UnitCurve.easeIn.value(at: linear)
    }

    private static func interpolate(from: CGSize, to: CGSize, progress: Double) -> CGSize {
        CGSize(width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }
}
