import AppKit
import SwiftUI
import QuartzCore

/// Only these tiny layers animate. Discrete keyframes cap visible changes at 10 Hz;
/// Core Animation runs them without a SwiftUI state update or a process-side timer.
struct LayerAnimationView: NSViewRepresentable {
    enum Kind: Equatable { case activity(Double?), claude, codex, refresh }
    let kind: Kind
    let color: Color
    let running: Bool
    var glyph: BrandGlyphLoader.Glyph? = nil

    func makeNSView(context: Context) -> IndicatorView { IndicatorView() }
    func updateNSView(_ view: IndicatorView, context: Context) {
        view.configure(kind: kind, color: NSColor(color).cgColor, running: running, glyph: glyph)
    }
    static func dismantleNSView(_ view: IndicatorView, coordinator: ()) { view.stop() }
}

@MainActor final class IndicatorView: NSView {
    private let track = CAShapeLayer()
    private let mark = CAShapeLayer()
    private var glyph: BrandGlyphLoader.Glyph?
    private var kind: LayerAnimationView.Kind = .activity(nil)
    private var tint: CGColor?
    private var running = false
    private var lastSize = CGSize.zero
    private var configured = false
    private var snapshotTime: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A layer-hosting view lets Core Animation composite contents directly.
        // AppKit must not redraw a backing bitmap for compositor keyframes.
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(mark)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(kind: LayerAnimationView.Kind, color: CGColor, running: Bool, glyph: BrandGlyphLoader.Glyph? = nil) {
        guard !configured || self.kind != kind || tint != color || self.running != running || self.glyph !== glyph else { return }
        self.kind = kind; tint = color; self.running = running; self.glyph = glyph; configured = true
        rebuild()
    }
    override func layout() {
        super.layout()
        if lastSize != bounds.size { rebuild() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { rebuild() }
    }
    func stop() { mark.removeAllAnimations() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    private func rebuild() {
        lastSize = bounds.size
        stop()
        guard bounds.width > 0, bounds.height > 0, let tint else { return }
        UIRenderMetrics.recordLayerUpdate()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for shape in [track, mark] {
            shape.transform = CATransform3DIdentity
            shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            shape.bounds = CGRect(origin: .zero, size: bounds.size)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.path = nil; shape.fillColor = nil; shape.strokeColor = tint
            shape.lineCap = .round; shape.lineJoin = .round
            shape.opacity = 1
            shape.contentsScale = window?.backingScaleFactor ?? 2
        }
        mark.contents = nil
        if let glyph, kind == .claude || kind == .codex {
            mark.contents = glyph.raster(size: bounds.size, scale: window?.backingScaleFactor ?? 2, tint: tint)
            mark.contentsGravity = .resize
            animate("transform.rotation.z", duration: 8) { $0 * 2 * .pi }
            return
        }
        let width = bounds.width, height = bounds.height, size = min(width, height)
        switch kind {
        case let .activity(fraction):
            track.strokeColor = nil
            track.fillColor = tint.copy(alpha: 0.15)
            track.path = CGPath(roundedRect: bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
            mark.strokeColor = nil; mark.fillColor = tint
            let value = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            let sliderWidth = value.map { width * $0 } ?? min(width, max(5, width * 0.30))
            mark.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: sliderWidth, height: height),
                               cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
            if value == nil { animate("transform.translation.x", duration: 3.6) { (1 - cos($0 * 2 * .pi)) / 2 * (width - sliderWidth) } }
        case .claude:
            let path = CGMutablePath(), radius = size * 0.44
            let center = CGPoint(x: width / 2, y: height / 2)
            for index in 0..<12 {
                let angle = Double(index) * .pi / 6
                let outer = radius * (index.isMultiple(of: 3) ? 1 : 0.88)
                path.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.32, y: center.y + sin(angle) * radius * 0.32))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            }
            mark.path = path; mark.lineWidth = radius * 0.22
            animate("transform.rotation.z", duration: 8) { $0 * 2 * .pi }
        case .codex:
            let inset = size * 0.04
            track.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: size * 0.22,
                                cornerHeight: size * 0.22, transform: nil)
            track.lineWidth = max(1, size * 0.065)
            let bracket = CGMutablePath()
            bracket.move(to: CGPoint(x: width * 0.25, y: height * 0.33))
            bracket.addLine(to: CGPoint(x: width * 0.43, y: height * 0.5))
            bracket.addLine(to: CGPoint(x: width * 0.25, y: height * 0.67))
            let outline = CGMutablePath()
            if let border = track.path { outline.addPath(border) }
            outline.addPath(bracket); track.path = outline
            let cursor = CGMutablePath()
            cursor.move(to: CGPoint(x: width * 0.54, y: height * 0.67))
            cursor.addLine(to: CGPoint(x: width * 0.76, y: height * 0.67))
            outline.addPath(cursor)
            // Keep the complete terminal glyph inside its rotation circle, including stroke.
            var fit = CGAffineTransform(translationX: width / 2, y: height / 2)
                .scaledBy(x: 0.82, y: 0.82).translatedBy(x: -width / 2, y: -height / 2)
            mark.path = outline.copy(using: &fit)
            mark.lineWidth = max(1, size * 0.075) * 0.82
            track.path = nil
            animate("transform.rotation.z", duration: 8) { $0 * 2 * .pi }
        case .refresh:
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: width / 2, y: height / 2), radius: size * 0.23,
                        startAngle: 0, endAngle: .pi * 1.65, clockwise: false)
            mark.path = path; mark.lineWidth = 1.3
            animate("transform.rotation.z", duration: 1.2) { $0 * 2 * .pi }
        }
    }
    func snapshot(at time: Double, scale: CGFloat) -> CGImage? {
        snapshotTime = time
        defer { snapshotTime = nil; rebuild() }
        rebuild()
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer?.render(in: context)
        return context.makeImage()
    }

    private func animate(_ keyPath: String, duration: Double, value: (Double) -> Double) {
        guard running else { return }
        let count = Int((duration * 10).rounded())
        if let snapshotTime {
            // Sample the same discrete values as the compositor without opening a window.
            let phase = floor(snapshotTime.truncatingRemainder(dividingBy: duration) * 10) / Double(count)
            mark.setValue(value(phase), forKeyPath: keyPath)
            return
        }
        guard window != nil else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...count).map { value(Double($0) / Double(count)) }
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        mark.add(animation, forKey: "activity")
    }
}

/// Non-observable counters: instrumentation never invalidates a view.
@MainActor enum UIRenderMetrics {
    static var enabled = false
    static var bodies: UInt64 = 0
    static var draws: UInt64 = 0
    static var layerUpdates: UInt64 = 0
    static var glyphBitmapDecodes: UInt64 = 0
    static var glyphCacheHits: UInt64 = 0
    static func recordBody() { if enabled { bodies += 1 } }
    static func recordDraw() { if enabled { draws += 1 } }
    static func recordLayerUpdate() { if enabled { layerUpdates += 1 } }
}
