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
            let status = SystemStatusView(metrics: metrics, options: .init(), notch: notch, config: config)
            let plan = status.layoutPlan
            print("Top band \(hasNotch ? "notch" : "capsule") \(panelWidth) pt: level \(plan.level.rawValue), \(plan.placements)")
            #expect(!plan.hidden.contains { !$0.isNetwork })
            if hasNotch && panelWidth == 600 {
                // Realistic worst-case rate and fan widths leave room for both directions and all hardware.
                #expect(plan.level == .compactNetwork)
                #expect(plan.hidden.isEmpty)
            }
            if !hasNotch || panelWidth == 900 { #expect(plan.level == .full) }
            let regions = SystemTopBandLayout.regions(panelWidth: panelWidth,
                notchWidth: hasNotch ? notch.notchRect.width : nil, notchSafetyInset: config.notchSafetyInset)
            for item in plan.placements {
                if let region = regions.first(where: { $0.side == item.side }) {
                    #expect(item.x >= region.x)
                    #expect(item.x + item.width <= region.x + region.width)
                } else { Issue.record("Missing region for visible metric") }
            }
            #expect(plan.placements.first?.x == IslandLayout.expandedContentInset)
            if let last = plan.placements.last {
                #expect(abs(last.x + last.width - (panelWidth - IslandLayout.expandedContentInset)) < 0.001)
            }
        }
    }
    for item in SystemTopBandItem.allCases {
        print("Top band width \(item): full \(SystemStatusSizing.widths.width(of: item, at: .full)), text \(SystemStatusSizing.widths.width(of: item, at: .textOnly)), compact \(SystemStatusSizing.widths.width(of: item, at: .compactNetwork))")
    }
}

@MainActor @Test func gpuHardwareDigitsKeepTheirReservedWidths() {
    let notch = SnapshotExporter.metrics(hasNotch: true)
    var plans: [SystemTopBandPlan] = []
    for percent: Double in [0, 9, 31, 85, 97, 100] {
        let metrics = SystemMetrics(network: .init(downBytesPerSec: percent * 1024 * 1024, upBytesPerSec: percent, interfaces: []),
                                    fan: .init(fans: [.init(index: 0, rpm: percent == 0 ? 0 : 2507, minRPM: 0, maxRPM: 6000)]),
                                    memory: .init(usedBytes: UInt64(percent), totalBytes: 100),
                                    cpu: .init(percent: percent, sampleIntervalMs: 1000), gpu: .init(percent: percent))
        let status = SystemStatusView(metrics: metrics, options: .init(), notch: notch, config: .init())
        let plan = status.layoutPlan
        plans.append(plan)
        for placement in plan.placements {
            let width = NSHostingView(rootView: SystemStatusItemView(item: placement.item,
                value: status.value(placement.item, level: plan.level), level: plan.level)).fittingSize.width
            #expect(width <= placement.width)
        }
    }
    #expect(plans.allSatisfy { $0 == plans.first })
    #expect(NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: nil) != nil)
}

@MainActor @Test func gpuAndCPUShareExactColorThresholds() {
    for percent in [0.0, 31, 79.99] { #expect(SystemStatusView.utilizationColor(percent) == Theme.secondary) }
    for percent in [80.0, 85, 94.99] { #expect(SystemStatusView.utilizationColor(percent) == Theme.warning) }
    for percent in [95.0, 97, 100] { #expect(SystemStatusView.utilizationColor(percent) == Theme.critical) }
}

@MainActor @Test func topBandWorstCaseSlotsContainAllFormattedValues() {
    var rates: [Double?] = [nil, -1, .nan, .infinity, 0, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
    for exponent in 1...9 {
        let scale = pow(1024.0, Double(exponent))
        rates += [scale - 1, scale, scale * 2.8, scale * 9.99, scale * 99.99, scale * 999.99, scale * 1023.99]
    }
    for level in [SystemTopBandLevel.full, .textOnly, .compactNetwork] {
        for item in SystemTopBandItem.allCases {
            let values: [String]
            if item.isNetwork { values = rates.map { SystemTopBandFormat.rate($0, compact: level.compactRates) } }
            else if item == .fan { values = [0, 9, 2507, 65535, 99_999, 100_000, Double(UInt32.max), .nan].map(SystemTopBandFormat.fan) }
            else { values = ["—", "0%", "9%", "10%", "99%", "100%"] }
            for value in values {
                let actual = NSHostingView(rootView: SystemStatusItemView(item: item, value: value, level: level)).fittingSize.width
                #expect(actual <= SystemStatusSizing.widths.width(of: item, at: level))
            }
        }
    }
}
