import SwiftUI

// All rectangles use the hosting canvas's top-left coordinate space. AppKit
// converts window events into this space before testing the reported regions.
struct IslandInteractionRegion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case shape(bottomRadius: CGFloat, earRadius: CGFloat)
        case control(String)
        case scroll
    }
    var kind: Kind
    var rect: CGRect
}

struct IslandInteractionPreference: PreferenceKey {
    static let defaultValue: [IslandInteractionRegion] = []
    static func reduce(value: inout [IslandInteractionRegion], nextValue: () -> [IslandInteractionRegion]) {
        value += nextValue()
    }
}

@MainActor final class IslandInteractionGeometry {
    static let coordinateSpace = "islandHostingCanvas"
    var regions: [IslandInteractionRegion] = []

    func contains(_ point: CGPoint) -> Bool {
        regions.contains { region in
            guard case let .shape(bottomRadius, earRadius) = region.kind else { return false }
            return NotchShape(bottomRadius: bottomRadius, earRadius: earRadius).path(in: region.rect).contains(point)
        }
    }

    func isControl(_ point: CGPoint) -> Bool {
        regions.contains { region in
            if case .control = region.kind { return region.rect.contains(point) }
            return false
        }
    }
}

struct IslandInteractionCanvas<Content: View>: View {
    let content: Content
    let geometry: IslandInteractionGeometry
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: IslandInteractionGeometry.coordinateSpace)
            .onPreferenceChange(IslandInteractionPreference.self) { geometry.regions = $0 }
    }
}

extension View {
    func islandInteraction(_ kind: IslandInteractionRegion.Kind) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: IslandInteractionPreference.self, value: [
                    IslandInteractionRegion(kind: kind, rect: proxy.frame(in: .named(IslandInteractionGeometry.coordinateSpace)))
                ])
            }.allowsHitTesting(false)
        }
    }

    // Clip child control regions to the visible viewport as the document scrolls.
    func islandScrollViewport() -> some View {
        modifier(IslandScrollViewport())
    }
}

private struct IslandScrollViewport: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let viewport = proxy.frame(in: .named(IslandInteractionGeometry.coordinateSpace))
            content.transformPreference(IslandInteractionPreference.self) { regions in
                for index in regions.indices { regions[index].rect = regions[index].rect.intersection(viewport) }
                regions.append(IslandInteractionRegion(kind: .scroll, rect: viewport))
            }
        }
    }
}
