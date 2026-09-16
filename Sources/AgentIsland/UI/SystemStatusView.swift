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
            HStack(spacing: 10) {
                if options.network {
                    item("arrow.down", SystemMetricFormat.rate(metrics.network?.downBytesPerSec))
                    item("arrow.up", SystemMetricFormat.rate(metrics.network?.upBytesPerSec))
                }
            }
            .frame(width: rects.left.width, height: notch.notchRect.height)
            .padding(.horizontal, inset)
            Color.clear.frame(width: notch.notchRect.width)
            ViewThatFits(in: .horizontal) {
                hardware(compactFan: false)
                hardware(compactFan: true)
            }
            .frame(width: rects.right.width, height: notch.notchRect.height)
            .padding(.horizontal, inset)
        }
        .font(Theme.font(10, weight: .medium)).monospacedDigit()
        .foregroundStyle(Theme.secondary)
    }
    func hardware(compactFan: Bool) -> some View {
        HStack(spacing: 6) {
            if options.cpu {
                percentage("cpu", label: "CPU", text: metrics.cpu?.text ?? "—", color: cpuColor)
            }
            if options.memory {
                percentage("memorychip", label: "内存",
                           text: metrics.memory.map { "\(Int($0.percent.rounded()))%" } ?? "—", color: memoryColor)
            }
            if options.fan, let fan = metrics.fan?.fans.first {
                HStack(spacing: 3) {
                    Image(systemName: "fan")
                    if !compactFan { Text("风扇") }
                    valueSlot(fan.rpm == 0 ? "静止" : "\(Int(fan.rpm.rounded()))", prototype: "0000")
                }.lineLimit(1).fixedSize()
                    .foregroundStyle(fan.warning ? Theme.warning : Theme.secondary)
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
        Text(prototype).fixedSize().hidden().accessibilityHidden(true)
            .overlay(alignment: .leading) { Text(text).fixedSize() }
    }
    private var cpuColor: Color {
        let percent = metrics.cpu?.percent ?? 0
        return percent >= 95 ? Theme.critical : percent >= 80 ? Theme.warning : Theme.secondary
    }
    private var memoryColor: Color {
        let percent = metrics.memory?.percent ?? 0
        return percent >= 90 ? Theme.critical : percent >= 80 ? Theme.warning : Theme.secondary
    }
    private func item(_ symbol: String, _ text: String, color: Color = Theme.secondary) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text).lineLimit(1).fixedSize()
        }.foregroundStyle(color)
    }
}
