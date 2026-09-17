import SwiftUI
import IslandCore

struct SystemStatusView: View {
    let metrics: SystemMetrics
    let options: SystemMetricOptions
    let notch: NotchMetrics
    let config: IslandLayoutConfig

    var layoutPlan: SystemTopBandPlan {
        SystemTopBandLayout.plan(panelWidth: panelWidth, notchWidth: notch.hasNotch ? notch.notchRect.width : nil,
                                 notchSafetyInset: config.notchSafetyInset,
                                 widths: SystemStatusSizing.widths, options: options,
                                 gpuAvailable: metrics.gpu != nil, fanAvailable: metrics.fan?.fans.first != nil)
    }
    private var panelWidth: CGFloat { IslandLayout.size(for: .expanded, notch: notch, config: config).width }

    var body: some View {
        let plan = layoutPlan
        ZStack(alignment: .leading) {
            ForEach(plan.placements, id: \.item) { placement in
                let atTrailingEdge = placement.side != .left
                    && placement.item == plan.placements.last(where: { $0.side == placement.side })?.item
                SystemStatusItemView(item: placement.item, value: value(placement.item, level: plan.level), level: plan.level)
                    .foregroundStyle(color(placement.item))
                    // Keep the last visible group at the card edge, including its unused digit reserve.
                    .frame(width: placement.width, alignment: atTrailingEdge ? .trailing : .leading)
                    .offset(x: placement.x)
            }
        }.frame(width: panelWidth, height: notch.notchRect.height, alignment: .leading)
    }

    func value(_ item: SystemTopBandItem, level: SystemTopBandLevel) -> String {
        switch item {
        case .download: SystemTopBandFormat.rate(metrics.network?.downBytesPerSec, compact: level.compactRates)
        case .upload: SystemTopBandFormat.rate(metrics.network?.upBytesPerSec, compact: level.compactRates)
        case .cpu: metrics.cpu?.text ?? "—"
        case .gpu: metrics.gpu?.text ?? "—"
        case .memory: metrics.memory.map { "\(Int($0.percent.rounded()))%" } ?? "—"
        case .fan: metrics.fan?.fans.first.map { $0.rpm == 0 ? "静止" : "\(Int($0.rpm.rounded()))" } ?? "—"
        }
    }

    private func color(_ item: SystemTopBandItem) -> Color {
        switch item {
        case .cpu: Self.utilizationColor(metrics.cpu?.percent)
        case .gpu: Self.utilizationColor(metrics.gpu?.percent)
        case .memory: (metrics.memory?.percent ?? 0) >= 90 ? Theme.critical
            : (metrics.memory?.percent ?? 0) >= 80 ? Theme.warning : Theme.secondary
        case .fan: metrics.fan?.fans.first?.warning == true ? Theme.warning : Theme.secondary
        case .download, .upload: Theme.secondary
        }
    }
    static func utilizationColor(_ value: Double?) -> Color {
        let percent = value ?? 0
        return percent >= 95 ? Theme.critical : percent >= 80 ? Theme.warning : Theme.secondary
    }
}
