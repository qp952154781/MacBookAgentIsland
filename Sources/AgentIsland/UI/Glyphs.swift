import SwiftUI
import IslandCore

struct ClaudeGlyph: View {
    var tint: Color = Theme.claude
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) * 0.44
            for index in 0..<12 {
                let angle = Double(index) * .pi / 6
                let inner = radius * 0.32
                let outer = radius * (index.isMultiple(of: 3) ? 1 : 0.88)
                var ray = Path()
                ray.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                ray.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                context.stroke(ray, with: .color(tint), style: StrokeStyle(lineWidth: radius * 0.22, lineCap: .round))
            }
        }
    }
}

struct CodexGlyph: View {
    @Environment(\.displayScale) private var displayScale
    var tint: Color = Theme.codex
    var body: some View {
        GeometryReader { geometry in
            let indicator = IndicatorView(frame: CGRect(origin: .zero, size: geometry.size))
            let _ = indicator.configure(kind: .codex, color: NSColor(tint).cgColor, running: false)
            if let bitmap = indicator.snapshot(at: 0, scale: displayScale) {
                Image(decorative: bitmap, scale: displayScale).resizable().interpolation(.high)
            }
        }
    }
}

struct AgentGlyph: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.brandGlyphLoader) private var injectedLoader
    let agent: ProviderID
    var tint: Color?
    var working = false
    var animated = true
    var body: some View {
        let loader = injectedLoader ?? BrandGlyphLoader.shared
        let glyph = loader.glyph(for: agent)
        let color = tint ?? Theme.glyph(agent)
        Group {
            if animated {
                LayerAnimationView(kind: .provider(agent), color: color,
                                   running: working, glyph: glyph)
            } else if let glyph {
                // ImageRenderer cannot render NSViewRepresentable. Snapshots share
                // the exact pre-tinted pixel cache used by the live layer contents.
                GeometryReader { geometry in
                    if let bitmap = glyph.raster(size: geometry.size, scale: displayScale, tint: NSColor(color).cgColor) {
                        Image(decorative: bitmap, scale: displayScale).resizable().interpolation(.high)
                    }
                }
            } else {
                switch ProviderRegistry.descriptor(for: agent).iconSource.fallback {
                case .claude: ClaudeGlyph(tint: color)
                case .codex: CodexGlyph(tint: color)
                default:
                    Canvas { context, size in
                        let diameter = min(size.width, size.height) * 0.6
                        let rect = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2,
                                          width: diameter, height: diameter)
                        context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.3)
                    }
                }
            }
        }
    }
}
