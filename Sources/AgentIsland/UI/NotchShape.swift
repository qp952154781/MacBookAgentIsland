import SwiftUI

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var earRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, earRadius) }
        set { bottomRadius = newValue.first; earRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if earRadius == 0 {
            return RoundedRectangle(cornerRadius: min(bottomRadius, rect.height / 2), style: .continuous).path(in: rect)
        }
        let e = min(earRadius, rect.height / 2)
        let r = min(bottomRadius, (rect.height - e) / 2, (rect.width - 2 * e) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.minY + e),
                          control: CGPoint(x: rect.maxX - e, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + e + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX + e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct IslandTransition: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        content.opacity(progress).scaleEffect(0.96 + 0.04 * progress, anchor: .top).blur(radius: 5 * (1 - progress))
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .modifier(active: IslandTransition(progress: 0), identity: IslandTransition(progress: 1))
    }
}
