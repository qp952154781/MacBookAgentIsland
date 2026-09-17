import Foundation
import Testing
@testable import IslandCore

// Synthetic maximum-width inputs in points, matching the rounded 10 pt display style.
// No AppKit, live metrics, hardware, or rendering is needed to exercise the decisions.
private let bandWidths = SystemTopBandWidths(
    full: [.download: 78, .upload: 78, .cpu: 70, .gpu: 71, .memory: 69, .fan: 107],
    textOnly: [.download: 78, .upload: 78, .cpu: 55, .gpu: 55, .memory: 53, .fan: 91],
    compact: [.download: 50, .upload: 50, .cpu: 55, .gpu: 55, .memory: 53, .fan: 91])

private func bandPlan(_ capacity: SystemTopBandCapacity, options: SystemMetricOptions = .init(),
                      gpu: Bool = true, fan: Bool = true) -> SystemTopBandPlan {
    SystemTopBandLayout.plan(capacity: capacity, widths: bandWidths, options: options,
                             gpuAvailable: gpu, fanAvailable: fan)
}

@Test func topBand600NotchKeepsAllHardwareAndRespectsSafeWings() throws {
    let width = (600.0 - 185) / 2 - 6 - IslandLayout.expandedContentInset
    let plan = SystemTopBandLayout.plan(panelWidth: 600, notchWidth: 185, notchSafetyInset: 6,
        widths: bandWidths, options: .init(), gpuAvailable: true, fanAvailable: true)
    #expect(plan.level == .downloadOnly)
    #expect(plan.items(on: .left) == [.download, .fan])
    #expect(plan.items(on: .right) == [.cpu, .gpu, .memory])
    #expect(plan.hidden == [.upload])
    for side in [SystemTopBandPlacement.Side.left, .right] {
        let items = plan.placements.filter { $0.side == side }
        let start = side == .left ? IslandLayout.expandedContentInset : (600.0 + 185) / 2 + 6
        for item in items { #expect(item.x >= start && item.x + item.width <= start + width) }
        if side == .left { #expect(items.first?.x == IslandLayout.expandedContentInset) }
        else {
            let last = try #require(items.last)
            #expect(abs(last.x + last.width - 584) < 0.001)
        }
    }
    // Level 4 retains both rates but misses the padded left wing by 17.5 pt.
    #expect(50 * 2 + 91 + 2 * SystemTopBandLayout.spacing - width == 17.5)
}

@Test func topBand900NotchUsesFullHardwareWithIcons() {
    let plan = SystemTopBandLayout.plan(panelWidth: 900, notchWidth: 185, notchSafetyInset: 6,
        widths: bandWidths, options: .init(), gpuAvailable: true, fanAvailable: true)
    #expect(plan.level == .full)
    #expect(plan.level.showsIcons)
    #expect(plan.items(on: .left) == [.download, .upload])
    #expect(plan.items(on: .right) == [.cpu, .gpu, .memory, .fan])
    #expect(plan.hidden.isEmpty)
}

@Test func topBandCapsule600And900ShareOneEvenlySpacedRow() throws {
    for panelWidth: CGFloat in [600, 900] {
        let width = panelWidth - 2 * IslandLayout.expandedContentInset
        let plan = bandPlan(.row(width: width))
        #expect(plan.level == .full)
        #expect(plan.items(on: .row) == [.download, .upload, .cpu, .gpu, .memory, .fan])
        #expect(plan.items(on: .left).isEmpty && plan.items(on: .right).isEmpty)
        #expect(plan.hidden.isEmpty)
        #expect(plan.placements.first?.x == 0)
        let last = try #require(plan.placements.last)
        #expect(abs(last.x + last.width - width) < 0.001)
        let gaps = zip(plan.placements, plan.placements.dropFirst()).map { $1.x - $0.x - $0.width }
        #expect(gaps.allSatisfy { abs($0 - (gaps.first ?? 0)) < 0.001 })
        #expect((gaps.first ?? 0) >= SystemTopBandLayout.spacing)
    }
}

@Test func topBandTriesEachNotchCompressionLevelInOrder() {
    let cases: [(CGFloat, CGFloat, SystemTopBandLevel)] = [
        (195.5, 345.5, .full), (300, 250, .overflow), (260, 180, .textOnly),
        (210, 180, .compactNetwork), (195.5, 195.5, .downloadOnly), (100, 150, .hideHardware)
    ]
    for (left, right, level) in cases {
        let plan = bandPlan(.wings(left: left, right: right))
        #expect(plan.level == level)
        for item in plan.placements {
            #expect(item.x >= 0)
            #expect(item.x + item.width <= (item.side == .left ? left : right))
        }
        if level.rawValue < 5 { #expect(plan.items(on: .left).contains(.upload)) }
        if level != .hideHardware { #expect(!plan.hidden.contains { !$0.isNetwork }) }
    }
}

@Test func topBandOverflowMovesLowestPrioritiesBeforeRemovingIcons() {
    for (left, right, moved): (CGFloat, CGFloat, [SystemTopBandItem]) in [
        (275, 222, [.fan]), (350, 147, [.memory, .fan]), (427, 70, [.gpu, .memory, .fan])
    ] {
        let plan = bandPlan(.wings(left: left, right: right))
        #expect(plan.level == .overflow)
        #expect(plan.items(on: .left) == [.download, .upload] + moved)
        #expect(plan.items(on: .right).first == .cpu)
        #expect(plan.level.showsIcons)
        #expect(plan.hidden.isEmpty)
    }
}

@Test func topBandCapsuleSkipsOverflowAndCompressesBeforeHiding() {
    for (width, level): (CGFloat, SystemTopBandLevel) in [
        (568, .full), (450, .textOnly), (400, .compactNetwork), (350, .downloadOnly), (300, .hideHardware)
    ] {
        let plan = bandPlan(.row(width: width))
        #expect(plan.level == level)
        #expect(plan.placements.allSatisfy { $0.side == .row })
        if level != .hideHardware { #expect(!plan.hidden.contains { !$0.isNetwork }) }
    }
}

@Test func topBandHardwareHidesFanThenMemoryThenGPUThenCPU() {
    for (width, hardware): (CGFloat, [SystemTopBandItem]) in [
        (231, [.cpu, .gpu, .memory]), (230, [.cpu, .gpu]), (171, [.cpu]), (110, []), (49, [])
    ] {
        let plan = bandPlan(.row(width: width))
        #expect(plan.level == .hideHardware)
        #expect(plan.items(on: .row).filter { !$0.isNetwork } == hardware)
        #expect(plan.items(on: .row).contains(.download) == (width >= 50))
    }
}

@Test func topBandSwitchesAndUnavailableMetricsConsumeNoCapacity() {
    let none = SystemMetricOptions(network: false, fan: false, memory: false, cpu: false, gpu: false)
    #expect(bandPlan(.row(width: 0), options: none).placements.isEmpty)
    let unavailable = bandPlan(.row(width: 568), gpu: false, fan: false)
    #expect(unavailable.items(on: .row) == [.download, .upload, .cpu, .memory])
    #expect(unavailable.hidden.isEmpty)
    #expect(bandPlan(.row(width: 568), options: .init(cpu: false, gpu: false)).items(on: .row)
            == [.download, .upload, .memory, .fan])
    let hardwareOnly = bandPlan(.wings(left: 120, right: 230), options: .init(network: false))
    #expect(hardwareOnly.level == .overflow)
    #expect(hardwareOnly.items(on: .left) == [.fan])
    #expect(hardwareOnly.hidden.isEmpty)
}

@Test func topBandMissingCPUAllowsAllOtherHardwareToUseLeftWing() {
    let plan = bandPlan(.wings(left: 260, right: 0), options: .init(network: false, cpu: false))
    #expect(plan.level == .overflow)
    #expect(plan.items(on: .left) == [.gpu, .memory, .fan])
    #expect(plan.items(on: .right).isEmpty)
    #expect(plan.hidden.isEmpty)
}

@Test func topBandExactCapacityIsAcceptedAndSubpointDeficitCompresses() {
    #expect(bandPlan(.wings(left: 162, right: 335)).level == .full)
    #expect(bandPlan(.wings(left: 162, right: 334.9)).level != .full)
    #expect(bandPlan(.row(width: 503)).level == .full)
    #expect(bandPlan(.row(width: 502.9)).level == .textOnly)
}

@Test func topBandInvalidAndTinyCapacitiesNeverOverflow() {
    for capacity in [SystemTopBandCapacity.row(width: -10), .row(width: .nan), .row(width: .infinity),
                     .wings(left: -10, right: 0), .wings(left: .nan, right: 200)] {
        #expect(bandPlan(capacity).placements.isEmpty)
    }
    let invalidWidths = SystemTopBandWidths(full: [:], textOnly: [:], compact: [:])
    #expect(SystemTopBandLayout.plan(capacity: .row(width: 600), widths: invalidWidths,
        options: .init(), gpuAvailable: true, fanAvailable: true).placements.isEmpty)
}

@Test func topBandDecisionDoesNotDependOnCurrentValues() {
    let baseline = bandPlan(.wings(left: 195.5, right: 195.5))
    for percent in [0.0, 9, 31, 99, 100] {
        let metrics = SystemMetrics(fan: .init(fans: [.init(index: 0, rpm: percent, minRPM: 0, maxRPM: 6000)]),
                                    gpu: .init(percent: percent))
        let plan = bandPlan(.wings(left: 195.5, right: 195.5), gpu: metrics.gpu != nil, fan: metrics.fan != nil)
        #expect(plan == baseline)
    }
}

@Test func topBandCompactRatesPreserveDirectionsAndScaleUnits() {
    #expect(SystemTopBandFormat.rate(336 * 1024, compact: true) == "336K")
    #expect(SystemTopBandFormat.rate(2.8 * 1024 * 1024, compact: true) == "2.8M")
    #expect(SystemTopBandFormat.rate(2.5 * 1024 * 1024, compact: false) == "2.5 MB/s")
    #expect(SystemTopBandFormat.rate(0, compact: false) == "0 KB/s")
    #expect(SystemTopBandFormat.rate(0, compact: true) == "0K")
    #expect(SystemTopBandFormat.rate(1023.9 * 1024, compact: true) == "1.0M")
    #expect(SystemTopBandFormat.rate(2.5 * pow(1024, 4), compact: false) == "2.5 TB/s")
    for invalid: Double? in [nil, -.infinity, .infinity, .nan, -1] {
        for compact in [true, false] { #expect(SystemTopBandFormat.rate(invalid, compact: compact) == "—") }
    }
    #expect(SystemTopBandFormat.rate(.greatestFiniteMagnitude, compact: true) == "—")
    #expect(SystemTopBandFormat.rate(.greatestFiniteMagnitude, compact: false) == "—")
}

@Test func topBandRatesStayWithinThreeSignificantCharactersAndRollOver() {
    let k = 1024.0
    #expect(SystemTopBandFormat.rate(9.94 * k, compact: true) == "9.9K")
    #expect(SystemTopBandFormat.rate(9.96 * k, compact: true) == "10K")
    #expect(SystemTopBandFormat.rate(999.4 * k, compact: true) == "999K")
    #expect(SystemTopBandFormat.rate(999.5 * k, compact: true) == "1.0M")
    #expect(SystemTopBandFormat.rate(999.94 * k, compact: false) == "999.9 KB/s")
    #expect(SystemTopBandFormat.rate(999.95 * k, compact: false) == "1.0 MB/s")
    #expect(SystemTopBandFormat.rate(999.4 * pow(k, 4), compact: true) == "999T")
    #expect(SystemTopBandFormat.rate(999.5 * pow(k, 4), compact: true) == "—")
    #expect(SystemTopBandFormat.rate(999.95 * pow(k, 4), compact: false) == "—")
    // Every finite, in-range value renders with at most three significant characters plus a unit.
    var bytes = k
    while bytes < pow(k, 5) {
        let text = SystemTopBandFormat.rate(bytes, compact: true)
        if text != "—" { #expect(text.count <= 4, "\(bytes) → \(text)") }
        bytes *= 1.37
    }
}

@Test func topBandFanTextIsBoundedToRealisticRPM() {
    #expect(SystemTopBandFormat.fan(0) == "静止")
    #expect(SystemTopBandFormat.fan(2507.4) == "2507")
    #expect(SystemTopBandFormat.fan(99_999) == "99999")
    #expect(SystemTopBandFormat.fan(100_000) == "—")
    for invalid: Double? in [nil, -1, .nan, .infinity, Double(UInt32.max)] {
        #expect(SystemTopBandFormat.fan(invalid) == "—")
    }
}

@Test func topBandPanelCoordinatesAlignWithBothCardEdgesInEveryForm() throws {
    for notchWidth: CGFloat? in [185, nil] {
        for panelWidth: CGFloat in [600, 900] {
            let plan = SystemTopBandLayout.plan(panelWidth: panelWidth, notchWidth: notchWidth, notchSafetyInset: 6,
                widths: bandWidths, options: .init(), gpuAvailable: true, fanAvailable: true)
            let first = try #require(plan.placements.first)
            let last = try #require(plan.placements.last)
            let cardLeft = IslandLayout.expandedContentInset
            let cardRight = panelWidth - IslandLayout.expandedContentInset
            #expect(first.x == cardLeft)
            #expect(abs(last.x + last.width - cardRight) < 0.001)
            if let notchWidth {
                for item in plan.placements {
                    if item.side == .left { #expect(item.x + item.width <= (panelWidth - notchWidth) / 2 - 6) }
                    if item.side == .right { #expect(item.x >= (panelWidth + notchWidth) / 2 + 6) }
                }
            } else {
                let gaps = zip(plan.placements, plan.placements.dropFirst()).map { $1.x - $0.x - $0.width }
                #expect(gaps.allSatisfy { abs($0 - (gaps.first ?? 0)) < 0.001 })
            }
        }
    }
}

@Test func topBandOuterPaddingReducesCapacityWithoutChangingNotchSafety() {
    let normal = SystemTopBandLayout.regions(panelWidth: 600, notchWidth: 185, notchSafetyInset: 6)
    let wider = SystemTopBandLayout.regions(panelWidth: 600, notchWidth: 185, notchSafetyInset: 6, outerInset: 27)
    #expect(normal.first?.width == 185.5)
    #expect(wider.first?.width == 174.5)
    #expect(normal.last?.x == wider.last?.x)
    if let before = normal.first, let after = wider.first {
        #expect(before.x + before.width == after.x + after.width)
    }
    let plan = SystemTopBandLayout.plan(panelWidth: 600, notchWidth: 185, notchSafetyInset: 6, outerInset: 27,
        widths: bandWidths, options: .init(), gpuAvailable: true, fanAvailable: true)
    #expect(plan.level == .hideHardware)
    #expect(plan.hidden == [.upload, .fan])
    #expect(plan.placements.first?.x == 27)
    if let last = plan.placements.last { #expect(last.x + last.width == 573) }
}

@Test func topBandCardAlignmentSurvivesNotchAndSafetySizeChanges() throws {
    for notchWidth: CGFloat in [0, 100, 185, 240] {
        for safety: CGFloat in [0, 6, 12] {
            let regions = SystemTopBandLayout.regions(panelWidth: 900, notchWidth: notchWidth, notchSafetyInset: safety)
            let left = try #require(regions.first), right = try #require(regions.last)
            #expect(left.x == IslandLayout.expandedContentInset)
            #expect(left.x + left.width == (900 - notchWidth) / 2 - safety)
            #expect(right.x == (900 + notchWidth) / 2 + safety)
            #expect(right.x + right.width == 900 - IslandLayout.expandedContentInset)
        }
    }
}
