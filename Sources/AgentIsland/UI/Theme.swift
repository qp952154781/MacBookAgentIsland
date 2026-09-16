import SwiftUI
import IslandCore

enum Theme {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let codex = Color(red: 0.541, green: 0.706, blue: 1)
    static let codexGlyph = Color(red: 232.0 / 255, green: 234.0 / 255, blue: 240.0 / 255)
    static let warning = Color(red: 1, green: 0.710, blue: 0.278)
    static let critical = Color(red: 1, green: 0.373, blue: 0.341)
    static let card = Color.white.opacity(0.06)
    static func brand(_ agent: AgentKind) -> Color { agent == .claude ? claude : codex }
    static func glyph(_ agent: AgentKind) -> Color { agent == .claude ? claude : codexGlyph }
    static func quota(_ window: QuotaWindow?, agent: AgentKind, warningThreshold: Double = 70, criticalThreshold: Double = 90) -> Color {
        guard let window else { return secondary }
        return window.usedPercent >= criticalThreshold ? critical : window.usedPercent >= warningThreshold ? warning : brand(agent)
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
