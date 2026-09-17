import AppKit
import SwiftUI
import IslandCore

/// Used exclusively by valueText windows; percentage wings retain their existing views.
struct ValueTextWing: View {
    let value: String
    let descriptor: ProviderDescriptor
    let color: Color
    let fontSize: CGFloat
    let iconSize: CGFloat
    let spacing: CGFloat
    let width: CGFloat
    let height: CGFloat
    let leading: Bool
    var showIcon = true
    var period = ""
    var periodFontSize: CGFloat = 8

    var body: some View {
        let periodFont = ValueTextWingText.roundedFont(size: periodFontSize)
        let periodSpace = period.isEmpty ? 0 : ValueTextWingText.measure(period, font: periodFont) + 2
        let text = ValueTextWingText(value: value, fontSize: fontSize, availableWidth: width - periodSpace,
                                     iconSize: iconSize, spacing: spacing, showIcon: showIcon)
        HStack(spacing: spacing) {
            if leading && text.layout.showsIcon { icon }
            HStack(spacing: 2) {
                Text(text.value).font(Font(text.font)).foregroundStyle(color).lineLimit(1)
                    // Fixed intrinsic text plus an explicit scale prevents SwiftUI from truncating again.
                    .fixedSize().scaleEffect(text.layout.fontScale)
                    .frame(width: text.width).help(value)
                if !period.isEmpty {
                    Text(period).font(Font(periodFont)).foregroundStyle(Theme.secondary).fixedSize()
                }
            }
            if !leading && text.layout.showsIcon { icon }
        }.frame(width: width, height: height)
    }

    private var icon: some View {
        AgentGlyph(agent: descriptor.id, descriptor: descriptor, animated: false)
            .frame(width: iconSize, height: iconSize).clipped().accessibilityHidden(true)
    }
}

/// Shares exactly the same font and scale between measurement and display; no rendering is needed to fit text.
struct ValueTextWingText {
    let value: String
    let font: NSFont
    let layout: ValueTextWingLayout
    let width: CGFloat

    init(value: String, fontSize: CGFloat, availableWidth: CGFloat, iconSize: CGFloat,
         spacing: CGFloat, showIcon: Bool = true) {
        let font = Self.roundedFont(size: fontSize, monospacedDigits: true)
        let measured = Self.measure(value, font: font)
        let layout = ValueTextWingLayout(measuredTextWidth: measured, availableWidth: availableWidth,
                                         iconWidth: iconSize, spacing: spacing, hasIcon: showIcon)
        self.font = font
        self.layout = layout
        width = min(measured, layout.textWidth)
        self.value = ValueTextTruncation.displayText(value, availableWidth: layout.textWidth) {
            Self.measure($0, font: font) * ValueTextWingLayout.minimumScale
        }
    }

    static func roundedFont(size: CGFloat, monospacedDigits: Bool = false) -> NSFont {
        let base = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
                                    : NSFont.systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func measure(_ value: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: value, attributes: [.font: font]).size().width
    }
}
