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
        ValueTextContentLayout(iconSize: iconSize, spacing: spacing, hasIcon: showIcon,
                               iconOnLeft: leading, hasPeriod: !period.isEmpty) {
            Text(value).font(Theme.font(fontSize, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(ValueTextWingLayout.minimumScale)
                .truncationMode(.tail).help(value)
            if showIcon {
                AgentGlyph(agent: descriptor.id, descriptor: descriptor, animated: false)
                    // A zero proposal can actually hide this flexible frame after shrinking fails.
                    .frame(maxWidth: iconSize, maxHeight: iconSize).clipped().accessibilityHidden(true)
            }
            if !period.isEmpty {
                Text(period).font(Theme.font(periodFontSize)).foregroundStyle(Theme.secondary).fixedSize()
            }
        }.frame(width: width, height: height)
    }
}

private struct ValueTextContentLayout: Layout {
    let iconSize: CGFloat
    let spacing: CGFloat
    let hasIcon: Bool
    let iconOnLeft: Bool
    let hasPeriod: Bool

    private func periodWidth(_ subviews: Subviews) -> CGFloat {
        hasPeriod ? subviews[hasIcon ? 2 : 1].sizeThatFits(.unspecified).width : 0
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let text = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? (text.width + (hasIcon ? iconSize + spacing : 0)
                                                + (hasPeriod ? periodWidth(subviews) + 2 : 0)),
                      height: proposal.height ?? max(text.height, hasIcon ? iconSize : 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = subviews[0].sizeThatFits(.unspecified).width
        let period = periodWidth(subviews), periodSpace = hasPeriod ? period + 2 : 0
        let fit = ValueTextWingLayout(measuredTextWidth: measured, availableWidth: bounds.width - periodSpace,
                                     iconWidth: iconSize, spacing: spacing, hasIcon: hasIcon)
        let textWidth = min(measured, fit.textWidth)
        let iconSpace = fit.showsIcon ? iconSize + spacing : 0
        let total = textWidth + iconSpace + periodSpace
        let start = bounds.midX - total / 2
        let textX = start + (iconOnLeft ? iconSpace : 0)
        subviews[0].place(at: CGPoint(x: textX + textWidth / 2, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: textWidth, height: bounds.height))
        if hasIcon {
            let iconX = iconOnLeft ? start + iconSize / 2 : textX + textWidth + periodSpace + spacing + iconSize / 2
            subviews[1].place(at: CGPoint(x: iconX, y: bounds.midY), anchor: .center,
                              proposal: fit.showsIcon ? ProposedViewSize(width: iconSize, height: iconSize) : .zero)
        }
        if hasPeriod {
            subviews[hasIcon ? 2 : 1].place(at: CGPoint(x: textX + textWidth + 2 + period / 2, y: bounds.midY),
                                           anchor: .center, proposal: ProposedViewSize(width: period, height: bounds.height))
        }
    }
}
