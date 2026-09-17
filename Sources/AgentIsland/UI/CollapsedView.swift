import SwiftUI
import IslandCore

struct CollapsedView: View {
    let store: IslandStore
    let notch: NotchMetrics
    var active = false
    var animated = true
    var animationsVisible = true
    private var config: IslandLayoutConfig { store.layoutConfig }

    var body: some View {
        let providers = ProviderLayout.wings()
        HStack(alignment: .top, spacing: 0) {
            wing(providers.left, isLeading: true)
            Color.clear.frame(width: notch.notchRect.width)
            wing(providers.right, isLeading: false)
        }
        .frame(height: notch.notchRect.height, alignment: .top)
    }

    @ViewBuilder private func wing(_ agent: ProviderID?, isLeading: Bool) -> some View {
        if let agent { wingContent(agent, isLeading: isLeading) }
        else { Color.clear.frame(width: config.wingWidth, height: notch.notchRect.height) }
    }

    private func wingContent(_ agent: ProviderID, isLeading: Bool) -> some View {
        let quota = store.headline(for: agent)
        let working = store.workingSessions(for: agent)
        let wings = IslandLayout.wingRects(notch: notch, config: config)
        let contentWidth = (isLeading ? wings.left : wings.right).width
        return ZStack(alignment: .bottom) {
            HStack(spacing: config.wingWidth < 68 ? 3 : 5) {
                if !isLeading { percentage(quota, agent: agent, working: working) }
                AgentGlyph(agent: agent, tint: quota == nil ? Theme.secondary : nil, working: !working.isEmpty, animated: animated && animationsVisible)
                    .frame(width: config.wingWidth < 68 ? 13 : 14, height: config.wingWidth < 68 ? 13 : 14)
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
            .font(Theme.font(config.wingWidth < 68 ? 10 : 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(Theme.quota(quota, agent: agent, warningThreshold: store.warningThreshold, criticalThreshold: store.criticalThreshold))
            .fixedSize()
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
