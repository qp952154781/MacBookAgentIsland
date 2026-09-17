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
        let providers = ProviderLayout.wings(in: store.visibleProviderIDs)
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

    private func adaptiveWing(_ content: ProviderWingLayout.Content, leading: Bool) -> some View {
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
            color = Theme.quota(window, agent: id, warningThreshold: store.warningThreshold, criticalThreshold: store.criticalThreshold)
        case let .sessions(id, count): value = "\(count)"; label = "会话"; color = Theme.brand(id)
        case .cpu: value = metricPercent(store.systemMetrics.cpu?.percent); label = "CPU"; color = Theme.primary
        case .memory: value = metricPercent(store.systemMetrics.memory?.percent); label = "内存"; color = Theme.primary
        }
        return HStack(spacing: narrow ? 2 : 3) {
            if showBrand, let agent {
                AgentGlyph(agent: agent, working: !working.isEmpty, animated: animated && animationsVisible)
                    .frame(width: narrow ? 11 : 14, height: narrow ? 11 : 14)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Theme.font(narrow ? 9 : 12, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                if !label.isEmpty { Text(label).font(Theme.font(narrow ? 6 : 8)).foregroundStyle(Theme.secondary) }
            }.fixedSize().frame(height: notch.notchRect.height)
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
