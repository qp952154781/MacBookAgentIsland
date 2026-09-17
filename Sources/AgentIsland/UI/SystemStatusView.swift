import SwiftUI
import IslandCore

struct SystemStatusView: View {
    let metrics: SystemMetrics
    let options: SystemMetricOptions
    let notch: NotchMetrics
    let config: IslandLayoutConfig

    var body: some View {
        let rects = IslandLayout.expandedWingRects(notch: notch, config: config)
        let inset = notch.hasNotch ? config.notchSafetyInset : 0
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                network(includeUpload: true)
                network(includeUpload: false)
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(width: rects.left.width, height: notch.notchRect.height)
            .padding(.horizontal, inset)
            Color.clear.frame(width: notch.notchRect.width)
            ViewThatFits(in: .horizontal) {
                hardware(maximumItems: 4)
                hardware(maximumItems: 3)
                hardware(maximumItems: 2)
                hardware(maximumItems: 1)
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(width: rects.right.width, height: notch.notchRect.height)
            .padding(.horizontal, inset)
        }
        .font(Theme.font(10, weight: .medium)).monospacedDigit()
        .foregroundStyle(Theme.secondary)
    }
    func hardware(maximumItems: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(SystemHardwareLayout.items(options: options, metrics: metrics,
                                                maximumCount: maximumItems), id: \.self) { metric in
                switch metric {
                case .cpu:
                    percentage("cpu", label: "CPU", text: metrics.cpu?.text ?? "—",
                               color: Self.utilizationColor(metrics.cpu?.percent))
                case .gpu:
                    if let gpu = metrics.gpu {
                        percentage("square.3.layers.3d", label: "GPU", text: gpu.text,
                                   color: Self.utilizationColor(gpu.percent))
                    }
                case .memory:
                    percentage("memorychip", label: "内存",
                               text: metrics.memory.map { "\(Int($0.percent.rounded()))%" } ?? "—", color: memoryColor)
                case .fan:
                    if let fan = metrics.fan?.fans.first {
                        HStack(spacing: 3) {
                            Image(systemName: "fan")
                            Text("风扇")
                            valueSlot(fan.rpm == 0 ? "静止" : "\(Int(fan.rpm.rounded()))", prototype: "0000")
                        }.lineLimit(1).fixedSize()
                            .foregroundStyle(fan.warning ? Theme.warning : Theme.secondary)
                    }
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func percentage(_ symbol: String, label: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(label)
            valueSlot(text, prototype: "100%")
        }.lineLimit(1).fixedSize().foregroundStyle(color)
    }
    // Reserve the actual font width; changing digits never moves the next group.
    private func valueSlot(_ text: String, prototype: String) -> some View {
        ZStack(alignment: .leading) {
            Text(prototype).fixedSize().hidden().accessibilityHidden(true)
            Text(text).fixedSize()
        }
    }
    static func utilizationColor(_ value: Double?) -> Color {
        let percent = value ?? 0
        return percent >= 95 ? Theme.critical : percent >= 80 ? Theme.warning : Theme.secondary
    }
    private var memoryColor: Color {
        let percent = metrics.memory?.percent ?? 0
        return percent >= 90 ? Theme.critical : percent >= 80 ? Theme.warning : Theme.secondary
    }
    private func network(includeUpload: Bool) -> some View {
        HStack(spacing: 10) {
            if options.network {
                item("arrow.down", SystemMetricFormat.rate(metrics.network?.downBytesPerSec))
                if includeUpload { item("arrow.up", SystemMetricFormat.rate(metrics.network?.upBytesPerSec)) }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func item(_ symbol: String, _ text: String, color: Color = Theme.secondary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).fixedSize()
        }.foregroundStyle(color)
    }
}
