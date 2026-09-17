import Foundation
import SwiftUI
import AppKit
import Testing
@testable import IslandCore
@testable import AgentIsland

@Test func cpuDifferencesIncludeNiceAndPreserveZeroDelta() throws {
    var difference = CPUDifferencer()
    let baseline = CPUCounter(user: 100, system: 50, idle: 200, nice: 10)
    #expect(difference.reading(for: baseline, time: 0) == nil)
    #expect(difference.reading(for: baseline, time: 0.25) == nil)
    let next = CPUCounter(user: 110, system: 55, idle: 280, nice: 15)
    let sample = difference.reading(for: next, time: 1.25)
    let reading = try #require(sample)
    #expect(reading.percent == 20)
    #expect(reading.sampleIntervalMs == 1000)
    let zero = difference.reading(for: next, time: 2.25)
    let unchanged = try #require(zero)
    #expect(unchanged.percent == 20)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SystemMetrics(cpu: reading))) as? [String: Any])
    let cpu = try #require(json["cpu"] as? [String: Double])
    #expect(cpu == ["percent": 20, "sampleIntervalMs": 1000])
}

@Test func cpuAllStatesWrapBeforeWideSum() throws {
    var difference = CPUDifferencer()
    _ = difference.reading(for: .init(user: .max - 4, system: .max - 4, idle: .max - 4, nice: .max - 4), time: 0)
    let sample = difference.reading(for: .init(user: 5, system: 0, idle: 75, nice: 0), time: 0.25)
    let reading = try #require(sample)
    #expect(reading.percent == 20)
    #expect(reading.sampleIntervalMs == 250)
    var wide = CPUDifferencer()
    _ = wide.reading(for: .init(user: 0, system: 0, idle: 0, nice: 0), time: 0)
    #expect(wide.reading(for: .init(user: .max, system: .max, idle: .max, nice: .max), time: 1)?.percent == 75)
}

@MainActor @Test func cpuCadenceHotSettingsCollapseAndSuspension() async {
    let settings = AppSettings(), store = IslandStore()
    settings.showGPU = false; settings.showNetwork = false; settings.showMemory = false; settings.showFan = false
    settings.apply(to: store)
    let scheduler = ManualSystemScheduler(), provider = FakeSystemProvider()
    let model = IslandViewModel(store: store)
    settings.onChange = { settings.apply(to: store); model.updateSystemMetrics() }
    defer { settings.onChange = nil }
    model.enableSystemMetrics(provider: provider, scheduler: scheduler)
    #expect(await provider.cpuCalls == 0)
    model.togglePinned()
    await scheduler.waitForDeadlines([0.25])
    #expect(store.systemMetrics.cpu == nil)
    #expect(await provider.cpuCalls == 1)
    await scheduler.advance(to: 0.25)
    await scheduler.waitForDeadlines([1.25])
    #expect(store.systemMetrics.cpu?.percent == 20)
    #expect(store.systemMetrics.cpu?.sampleIntervalMs == 250)
    await scheduler.advance(to: 1.25)
    await scheduler.waitForDeadlines([2.25])
    #expect(store.systemMetrics.cpu?.sampleIntervalMs == 1000)
    settings.showCPU = false
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 10)
    #expect(await provider.cpuCalls == 3)
    #expect(store.systemMetrics.cpu == nil)
    settings.showCPU = true
    await scheduler.waitForDeadlines([10.25])
    #expect(store.systemMetrics.cpu == nil)
    model.animationsVisible = false // Lock/sleep use the same visibility gate.
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 20)
    #expect(await provider.cpuCalls == 4)
    model.animationsVisible = true
    await scheduler.waitForDeadlines([20.25])
    #expect(store.systemMetrics.cpu == nil)
    model.clickedOutside()
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 30)
    #expect(await provider.cpuCalls == 5)
    model.togglePinned()
    await scheduler.waitForDeadlines([30.25])
    #expect(store.systemMetrics.cpu == nil)
    model.stop()
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 100)
    #expect(await provider.cpuCalls == 6)
}

@MainActor @Test func cpuHardwareFitsWingsAndKeepsWidthAcrossDigits() {
    for hasNotch in [true, false] {
        let notch = SnapshotExporter.metrics(hasNotch: hasNotch)
        let available = IslandLayout.expandedWingRects(notch: notch).right.width
        var widths: [CGFloat] = []
        for (usedBytes, rpm): (UInt64, Double) in [(9, 0), (73, 2500), (100, 6550)] {
            for percent: Double? in [nil, 9, 12, 85, 100] {
                let metrics = SystemMetrics(
                    fan: .init(fans: [.init(index: 0, rpm: rpm, minRPM: 0, maxRPM: 6550)]),
                    memory: .init(usedBytes: usedBytes, totalBytes: 100),
                    cpu: percent.map { .init(percent: $0, sampleIntervalMs: 1000) })
                let status = SystemStatusView(metrics: metrics, options: .init(), notch: notch, config: .init())
                let view = NSHostingView(rootView: status.hardware(maximumItems: hasNotch ? 2 : 4)
                    .font(Theme.font(10, weight: .medium)).monospacedDigit())
                let width = view.fittingSize.width
                #expect(width <= available)
                widths.append(width)
            }
        }
        #expect(widths.allSatisfy { abs($0 - (widths.first ?? 0)) < 0.01 })
    }
}
