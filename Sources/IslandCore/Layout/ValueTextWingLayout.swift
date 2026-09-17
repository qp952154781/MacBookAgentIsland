import Foundation

/// Fits a measured value without mistaking a truncated balance for a smaller amount.
/// The caller reserves any period label before supplying the available width.
public struct ValueTextWingLayout: Equatable, Sendable {
    public static let minimumScale = 0.75
    public let showsIcon: Bool
    public let textWidth: Double
    public let fontScale: Double
    public let truncates: Bool

    public init(measuredTextWidth: Double, availableWidth: Double, iconWidth: Double, spacing: Double,
                hasIcon: Bool = true) {
        func width(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        let measured = width(measuredTextWidth), available = width(availableWidth)
        let besideIcon = max(0, available - width(iconWidth) - width(spacing))
        // Keep the icon if shrinking to at least 75% can preserve the entire value.
        showsIcon = hasIcon && measured * Self.minimumScale <= besideIcon
        textWidth = showsIcon ? besideIcon : available
        fontScale = measured > 0 ? min(1, max(Self.minimumScale, textWidth / measured)) : 1
        // Truncation is allowed only after the icon's space has been reclaimed.
        truncates = measured * Self.minimumScale > textWidth
    }
}
