import SwiftUI
import IslandCore

enum Theme {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let claude = brand(.claude)
    static let codex = brand(.codex)
    static let codexGlyph = glyph(.codex)
    static let warning = Color(red: 1, green: 0.710, blue: 0.278)
    static let critical = Color(red: 1, green: 0.373, blue: 0.341)
    static let card = Color.white.opacity(0.06)
    static func color(_ rgb: ProviderDescriptor.RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
    static func brand(_ agent: ProviderID) -> Color { color(ProviderRegistry.descriptor(for: agent).brandColor) }
    static func glyph(_ agent: ProviderID) -> Color { color(ProviderRegistry.descriptor(for: agent).glyphColor) }
    static func quota(_ window: QuotaWindow?, agent: ProviderID, warningThreshold: Double = 70, criticalThreshold: Double = 90, descriptor: ProviderDescriptor? = nil) -> Color {
        guard let window else { return secondary }
        let brand = descriptor.map { color($0.brandColor) } ?? brand(agent)
        if window.valueText != nil { return brand }
        return window.usedPercent >= criticalThreshold ? critical : window.usedPercent >= warningThreshold ? warning : brand
    }
    static func phase(_ phase: SessionPhase) -> Color {
        switch phase {
        case .thinking, .compacting: Color(red: 0.70, green: 0.53, blue: 1)
        case .runningTool: Color(red: 0.30, green: 0.64, blue: 1)
        case .waitingInput: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .waitingPermission, .retrying: warning
        case .error: critical
        case .idle, .ended: secondary
        }
    }
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        DisplayTime.duration(seconds)
    }
}
