import AppKit
import SwiftUI
import Testing
@testable import IslandCore
@testable import AgentIsland

@MainActor @Test func gpuHardwareFitsBothPanelWidthsAndPreservesPriority() {
    let metrics = SystemMetrics(fan: .init(fans: [.init(index: 0, rpm: 2507, minRPM: 0, maxRPM: 6000)]),
                                memory: .init(usedBytes: 72, totalBytes: 100),
                                cpu: .init(percent: 12, sampleIntervalMs: 1000), gpu: .init(percent: 31))
    for hasNotch in [true, false] {
        for panelWidth: CGFloat in [600, 900] {
            let notch = SnapshotExporter.metrics(hasNotch: hasNotch)
            var config = IslandLayoutConfig()
            config.expandedWidth = panelWidth
            let rects = IslandLayout.expandedWingRects(notch: notch, config: config)
            let status = SystemStatusView(metrics: metrics, options: .init(), notch: notch, config: config)
            let widths = (0...4).map { count in
                NSHostingView(rootView: status.hardware(maximumItems: count)
                    .font(Theme.font(10, weight: .medium)).monospacedDigit()).fittingSize.width
            }
            // ViewThatFits selects the first fixed-size candidate that fits the actual safe wing.
            let selected = (0...4).reversed().first { widths[$0] <= rects.right.width } ?? 0
            #expect(selected == (hasNotch && panelWidth == 600 ? 2 : 4))
            #expect(widths[selected] <= rects.right.width)
            for count in 1...4 {
                #expect(widths[count] > widths[count - 1])
                let justTooNarrow = widths[count] - 0.1
                let next = (0...4).reversed().first { widths[$0] <= justTooNarrow } ?? 0
                #expect(next == count - 1)
                let items = SystemHardwareLayout.items(options: .init(), metrics: metrics, maximumCount: next)
                #expect(items == Array(SystemHardwareMetric.allCases.prefix(next)))
            }
            let safety = hasNotch ? config.notchSafetyInset : 0
            #expect(rects.right.minX >= notch.notchRect.maxX + safety)
            #expect(rects.right.maxX <= IslandLayout.frame(for: .expanded, notch: notch, config: config).maxX - safety)
        }
    }
}

@MainActor @Test func gpuHardwareDigitsKeepTheirReservedWidths() {
    let notch = SnapshotExporter.metrics(hasNotch: true)
    var widths: [CGFloat] = []
    for percent: Double in [0, 9, 31, 85, 97, 100] {
        let metrics = SystemMetrics(fan: .init(fans: [.init(index: 0, rpm: percent == 0 ? 0 : 2507, minRPM: 0, maxRPM: 6000)]),
                                    memory: .init(usedBytes: UInt64(percent), totalBytes: 100),
                                    cpu: .init(percent: percent, sampleIntervalMs: 1000), gpu: .init(percent: percent))
        let status = SystemStatusView(metrics: metrics, options: .init(), notch: notch, config: .init())
        widths.append(NSHostingView(rootView: status.hardware(maximumItems: 4)
            .font(Theme.font(10, weight: .medium)).monospacedDigit()).fittingSize.width)
    }
    #expect(widths.allSatisfy { abs($0 - (widths.first ?? 0)) < 0.01 })
    #expect(NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil) != nil)
}

@MainActor @Test func gpuAndCPUShareExactColorThresholds() {
    for percent in [0.0, 31, 79.99] { #expect(SystemStatusView.utilizationColor(percent) == Theme.secondary) }
    for percent in [80.0, 85, 94.99] { #expect(SystemStatusView.utilizationColor(percent) == Theme.warning) }
    for percent in [95.0, 97, 100] { #expect(SystemStatusView.utilizationColor(percent) == Theme.critical) }
}
