import SwiftUI
import IslandCore

struct CollapsedView: View {
    let store: IslandStore
    let notch: NotchMetrics
    var active = false
    var animated = true
    var animationsVisible = true
    private var config: IslandLayoutConfig { store.layoutConfig }
    // Sizing tiers for the paired quota wings. The compact tier exists only below
    // `IslandLayout.compactWingThreshold`, so wider wings render exactly as before.
    private var compact: Bool { config.wingWidth < IslandLayout.compactWingThreshold }
    private var narrow: Bool { config.wingWidth < 68 }
    private var pairGlyphSize: CGFloat { compact ? 11 : narrow ? 13 : 14 }
    private var pairSpacing: CGFloat { compact ? 2 : narrow ? 3 : 5 }
    private var pairFontSize: CGFloat { compact ? 9 : narrow ? 10 : 12 }

    var body: some View {
        let providers = (left: store.providerWings.left.agent, right: store.providerWings.right.agent)
        let adaptive = store.providerWings
        HStack(alignment: .top, spacing: 0) {
            if store.visibleProviderIDs.count >= 2, let id = providers.left, store.quotaProviderIDs.contains(id) {
                wing(id, isLeading: true)
            } else { adaptiveWing(adaptive.left, leading: true) }
            Color.clear.frame(width: notch.notchRect.width)
            if store.visibleProviderIDs.count >= 2, let id = providers.right, store.quotaProviderIDs.contains(id) {
                wing(id, isLeading: false)
            } else { adaptiveWing(adaptive.right, leading: false) }
        }
        .frame(height: notch.notchRect.height, alignment: .top)
    }

    @ViewBuilder private func adaptiveWing(_ content: ProviderWingLayout.Content, leading: Bool) -> some View {
        if case let .quota(agent, window, period) = content, let value = window?.valueText {
            let narrow = config.wingWidth < 68
            valueTextWing(value, window: window, agent: agent, leading: leading, fontSize: narrow ? 9 : 12,
                          iconSize: narrow ? 11 : 14, spacing: narrow ? 2 : 3,
                          showIcon: !store.providerWings.singleProvider || leading, period: period ?? "")
        } else {
            standardAdaptiveWing(content, leading: leading)
        }
    }

    private func standardAdaptiveWing(_ content: ProviderWingLayout.Content, leading: Bool) -> some View {
        let agent = content.agent
        let showBrand = agent != nil && (!store.providerWings.singleProvider || leading)
        let working = showBrand ? agent.map { store.workingSessions(for: $0) } ?? [] : []
        let narrow = config.wingWidth < 68
        let value: String
        let label: String
        let color: Color
        switch content {
        case let .quota(id, window, period):
            value = store.quotaDisplayMode.percent(window); label = period ?? ""
            color = Theme.quota(window, agent: id, warningThreshold: store.warningThreshold, criticalThreshold: store.criticalThreshold, descriptor: store.descriptor(for: id))
        case let .sessions(id, count): value = "\(count)"; label = "会话"; color = Theme.brand(id)
        case .cpu: value = metricPercent(store.systemMetrics.cpu?.percent); label = "CPU"; color = Theme.primary
        case .memory: value = metricPercent(store.systemMetrics.memory?.percent); label = "内存"; color = Theme.primary
        }
        return HStack(spacing: narrow ? 2 : 3) {
            if showBrand, let agent {
                AgentGlyph(agent: agent, descriptor: store.descriptor(for: agent), working: !working.isEmpty, animated: animated && animationsVisible)
                    .frame(width: narrow ? 11 : 14, height: narrow ? 11 : 14)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Theme.font(narrow ? 9 : 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                if !label.isEmpty { Text(label).font(Theme.font(narrow ? 6 : 8)).foregroundStyle(Theme.secondary) }
            }.modifier(WingValueSizing(agent: agent, maximumWidth: max(12, config.wingWidth - (showBrand ? 23 : 8))))
                .frame(height: notch.notchRect.height)
                .overlay(alignment: .bottom) {
                    if active, !working.isEmpty, let agent {
                        ActivityLine(fraction: working.first?.plan?.fraction, color: Theme.brand(agent), animated: animated, running: animationsVisible)
                            .frame(width: 18, height: 2).padding(.bottom, 3)
                    }
                }
        }.offset(y: active && !working.isEmpty ? -2 : 0)
            .frame(width: config.wingWidth, height: notch.notchRect.height)
    }
    private func metricPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }

    @ViewBuilder private func wing(_ agent: ProviderID?, isLeading: Bool) -> some View {
        if let agent {
            if let window = store.headline(for: agent), let value = window.valueText {
                valueTextWing(value, window: window, agent: agent, leading: isLeading,
                              fontSize: pairFontSize, iconSize: pairGlyphSize, spacing: pairSpacing)
            } else { wingContent(agent, isLeading: isLeading) }
        }
        else { Color.clear.frame(width: config.wingWidth, height: notch.notchRect.height) }
    }

    private func valueTextWing(_ value: String, window: QuotaWindow?, agent: ProviderID, leading: Bool,
                               fontSize: CGFloat, iconSize: CGFloat, spacing: CGFloat,
                               showIcon: Bool = true, period: String = "") -> some View {
        let wings = IslandLayout.wingRects(notch: notch, config: config)
        return ValueTextWing(value: value, descriptor: store.descriptor(for: agent),
                             color: Theme.quota(window, agent: agent, warningThreshold: store.warningThreshold,
                                                criticalThreshold: store.criticalThreshold, descriptor: store.descriptor(for: agent)),
                             fontSize: fontSize, iconSize: iconSize, spacing: spacing,
                             width: (leading ? wings.left : wings.right).width, height: notch.notchRect.height,
                             leading: leading, showIcon: showIcon, period: period, periodFontSize: config.wingWidth < 68 ? 6 : 8)
            .frame(width: config.wingWidth, height: notch.notchRect.height)
    }

    private func wingContent(_ agent: ProviderID, isLeading: Bool) -> some View {
        let quota = store.headline(for: agent)
        let working = store.workingSessions(for: agent)
        let wings = IslandLayout.wingRects(notch: notch, config: config)
        let contentWidth = (isLeading ? wings.left : wings.right).width
        return ZStack(alignment: .bottom) {
            HStack(spacing: pairSpacing) {
                if !isLeading { percentage(quota, agent: agent, working: working) }
                AgentGlyph(agent: agent, tint: quota == nil ? Theme.secondary : nil, descriptor: store.descriptor(for: agent), working: !working.isEmpty, animated: animated && animationsVisible)
                    .frame(width: pairGlyphSize, height: pairGlyphSize)
                    .overlay(alignment: .topTrailing) {
                        if working.count > 1 {
                            Text("\(working.count)").font(Theme.font(7, weight: .bold))
                                .padding(2).background(.black, in: Circle()).offset(x: 5, y: -5)
                        }
                    }
                    .offset(y: active ? -2 : 0)
                if isLeading { percentage(quota, agent: agent, working: working) }
            }
            .frame(width: contentWidth, height: notch.notchRect.height)
        }.frame(width: config.wingWidth)
    }
    private func percentage(_ quota: QuotaWindow?, agent: ProviderID, working: [AgentSession]) -> some View {
        let label = store.health[agent] == nil && quota == nil ? "···" : store.quotaDisplayMode.percent(quota)
        return Text(label)
            .font(Theme.font(pairFontSize, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.quota(quota, agent: agent, warningThreshold: store.warningThreshold, criticalThreshold: store.criticalThreshold, descriptor: store.descriptor(for: agent)))
            // Glyph + spacing + notch and outer margins: 13+3+6+4 normally, 11+2+6+3 compact.
            .modifier(WingValueSizing(agent: agent, maximumWidth: max(12, config.wingWidth - (compact ? 22 : 26))))
            .offset(y: active ? -2 : 0)
            .frame(height: notch.notchRect.height)
            .overlay {
                if active && !working.isEmpty {
                    GeometryReader { geometry in
                        ActivityLine(fraction: working.first?.plan?.fraction, color: Theme.brand(agent),
                                     animated: animated, running: animationsVisible)
                            .id("\(working.first?.id ?? "none"):\(working.first?.plan != nil)")
                            .frame(width: label.contains("%") ? min(28, max(14, geometry.size.width)) : 18, height: 2)
                            .position(x: geometry.size.width / 2, y: geometry.size.height - 5)
                    }
                }
            }
    }
}

private struct WingValueSizing: ViewModifier {
    let agent: ProviderID?
    let maximumWidth: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if let agent, !ProviderRegistry.orderedIDs.contains(agent) {
            content.lineLimit(1).truncationMode(.tail).frame(maxWidth: maximumWidth)
        } else {
            // Preserve the intrinsic text width and glyph placement of the built-in wings.
            content.fixedSize()
        }
    }
}

private struct ActivityLine: View {
    let fraction: Double?
    let color: Color
    let animated: Bool
    let running: Bool
    var body: some View {
        if animated {
            LayerAnimationView(kind: .activity(fraction), color: color, running: running && fraction == nil)
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: fraction.flatMap { $0.isFinite ? geometry.size.width * min(1, max(0, $0)) : nil }
                               ?? min(geometry.size.width, max(5, geometry.size.width * 0.30)))
                }
            }
        }
    }
}
