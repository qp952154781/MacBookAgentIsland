import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

@Test func gpuParsesOnlyDeviceUtilization() {
    #expect(GPUMetrics.parse([["Device Utilization %": 31, "Renderer Utilization %": 98,
                              "Tiler Utilization %": 99, "Unknown": "ignored"]])?.percent == 31)
    #expect(GPUMetrics.parse([["Device Utilization %": 12.5]])?.percent == 12.5)
    #expect(GPUMetrics.parse([["Device Utilization %": 0]])?.text == "0%")
}

@Test func gpuMissingAndNonNumericValuesAreUnavailable() {
    for dictionary: [String: Any] in [[:], ["Renderer Utilization %": 90],
        ["Device Utilization %": "31"], ["Device Utilization %": true],
        ["Device Utilization %": NSNull()], ["Device Utilization %": [31]]] {
        #expect(GPUMetrics.parse([dictionary]) == nil)
    }
}

@Test func gpuNonFiniteValuesAreUnavailable() {
    for percent in [Double.nan, .infinity, -.infinity] {
        #expect(GPUMetrics.parse([["Device Utilization %": percent]]) == nil)
    }
}

@Test func gpuClampsOutOfRangeValues() {
    #expect(GPUMetrics.parse([["Device Utilization %": -12]])?.percent == 0)
    #expect(GPUMetrics.parse([["Device Utilization %": 134]])?.percent == 100)
}

@Test func gpuUsesMaximumAcrossAccelerators() {
    #expect(GPUMetrics.parse([["Device Utilization %": 13], [:], ["Device Utilization %": "bad"],
                              ["Device Utilization %": 87], ["Device Utilization %": 31]])?.percent == 87)
}

@Test func gpuNoAcceleratorsReturnsNil() {
    #expect(GPUMetrics.parse([]) == nil)
}

@Test func gpuDumpEncodesPercentOrExplicitNull() throws {
    for percent: Double? in [nil, 0, 31, 100] {
        let metrics = SystemMetrics(gpu: percent.map { .init(percent: $0) })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any])
        if let percent { #expect(json["gpu"] as? [String: Double] == ["percent": percent]) }
        else { #expect(json["gpu"] is NSNull) }
    }
}

@Test func gpuServicesStayCachedAndReleaseOnceOnReset() {
    var cache = GPUServiceCache(), matches = 0, reads = 0
    var releases: [UInt32] = []
    for time in 0..<5 {
        let reading = cache.sample(at: Double(time), match: { matches += 1; return [1, 2] }, read: {
            reads += 1; return ["Device Utilization %": $0 == 1 ? 20 : 80]
        }, release: { releases.append($0) })
        #expect(reading?.percent == 80)
    }
    #expect(matches == 1)
    #expect(reads == 10)
    #expect(releases.isEmpty)
    cache.reset { releases.append($0) }
    cache.reset { releases.append($0) }
    #expect(releases == [1, 2])
}

@Test func gpuFailedServicesAreReleasedAndRematched() {
    var cache = GPUServiceCache(), matches = 0
    var releases: [UInt32] = []
    for time in 0..<3 {
        let result = cache.sample(at: Double(time), match: { matches += 1; return [UInt32(matches)] },
                                 read: { _ in time == 1 ? nil : ["Device Utilization %": 31] },
                                 release: { releases.append($0) })
        #expect(result?.percent == (time == 1 ? nil : 31))
    }
    #expect(matches == 2)
    #expect(releases == [1])
    #expect(cache.services == [2])
    cache.reset { releases.append($0) }
    #expect(releases == [1, 2])
}

@Test func gpuUnavailableRegistryRetriesWithBackoffAndReset() {
    for handles: [UInt32] in [[], [1]] {
        var cache = GPUServiceCache(), matches = 0
        var releases: [UInt32] = []
        func sample(_ time: Double) {
            #expect(cache.sample(at: time, match: { matches += 1; return handles },
                                 read: { _ in nil }, release: { releases.append($0) }) == nil)
        }
        for time in 0..<30 { sample(Double(time)) }
        #expect(matches == 1)
        sample(30)
        #expect(matches == 2)
        cache.reset { releases.append($0) }
        sample(31)
        #expect(matches == 3)
        #expect(releases.count == handles.count * 3)
    }
}

@Test func gpuUnsupportedStatisticsKeepServiceCached() {
    var cache = GPUServiceCache(), matches = 0
    for time in 0..<4 {
        #expect(cache.sample(at: Double(time), match: { matches += 1; return [1] },
                             read: { _ in ["Renderer Utilization %": 90] }, release: { _ in }) == nil)
    }
    #expect(matches == 1)
}

private actor FakeGPUReader: GPUReading {
    var samples = 0
    var resets = 0
    func sample() -> GPUMetrics? { samples += 1; return .init(percent: 42) }
    func reset() { resets += 1 }
}

@Test func gpuProviderUsesInjectedReaderAndResetsIt() async {
    let reader = FakeGPUReader()
    let provider = LiveSystemMetricsProvider(smc: FakeSMC(), gpu: reader)
    #expect(await provider.gpu()?.percent == 42)
    await provider.reset()
    #expect(await reader.samples == 1)
    #expect(await reader.resets == 1)
}

@MainActor @Test func gpuCadenceHotSettingsCollapseAndLockSleep() async {
    let settings = AppSettings(), store = IslandStore()
    settings.showCPU = false; settings.showNetwork = false; settings.showMemory = false; settings.showFan = false
    settings.apply(to: store)
    let scheduler = ManualSystemScheduler(), provider = FakeSystemProvider()
    let model = IslandViewModel(store: store)
    settings.onChange = { settings.apply(to: store); model.updateSystemMetrics() }
    defer { settings.onChange = nil }
    model.enableSystemMetrics(provider: provider, scheduler: scheduler)
    #expect(await provider.gpuCalls == 0)
    model.togglePinned()
    await scheduler.waitForDeadlines([1])
    #expect(store.systemMetrics.gpu?.percent == 31)
    #expect(await provider.gpuCalls == 1)
    await scheduler.advance(to: 1)
    await scheduler.waitForDeadlines([2])
    #expect(await provider.gpuCalls == 2)
    settings.showGPU = false
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 10)
    #expect(await provider.gpuCalls == 2)
    #expect(store.systemMetrics.gpu == nil)
    settings.showGPU = true
    await scheduler.waitForDeadlines([11])
    #expect(store.systemMetrics.gpu?.percent == 31)
    model.animationsVisible = false // Lock and sleep both use this gate.
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 20)
    #expect(await provider.gpuCalls == 3)
    #expect(store.systemMetrics.gpu == nil)
    model.updateSystemMetrics(reset: true) // Wake resets the registry cache while still suspended.
    model.animationsVisible = true
    await scheduler.waitForDeadlines([21])
    #expect(await provider.resets == 3)
    #expect(store.systemMetrics.gpu?.percent == 31)
    model.clickedOutside()
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 30)
    #expect(await provider.gpuCalls == 4)
    model.togglePinned()
    await scheduler.waitForDeadlines([31])
    #expect(store.systemMetrics.gpu?.percent == 31)
    model.stop()
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 100)
    #expect(await provider.gpuCalls == 5)
    #expect(await provider.cpuCalls == 0)
}

@MainActor private final class GPUSettingsDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor @Test func gpuSettingsDefaultOnAndPersistHotChanges() {
    let defaults = GPUSettingsDefaults(), settings = AppSettings(defaults: nil)
    #expect(settings.showGPU)
    let persistent = AppSettings(defaults: defaults), store = IslandStore()
    persistent.onChange = { persistent.apply(to: store) }
    defer { persistent.onChange = nil }
    persistent.showGPU = false
    #expect(!store.systemMetricOptions.gpu)
    #expect(!AppSettings(defaults: defaults).showGPU)
    persistent.showGPU = true
    #expect(store.systemMetricOptions.gpu)
    #expect(AppSettings(defaults: defaults).showGPU)
}

@Test func gpuUnavailableAndDisabledItemsDoNotConsumeWidth() {
    #expect(SystemTopBandLayout.enabledItems(options: .init(), gpuAvailable: false, fanAvailable: false)
            == [.download, .upload, .cpu, .memory])
    #expect(SystemTopBandLayout.enabledItems(options: .init(), gpuAvailable: true, fanAvailable: true)
            == [.download, .upload, .cpu, .gpu, .memory, .fan])
    #expect(SystemTopBandLayout.enabledItems(options: .init(cpu: false), gpuAvailable: true, fanAvailable: true)
            == [.download, .upload, .gpu, .memory, .fan])
    #expect(SystemTopBandLayout.enabledItems(options: .init(gpu: false), gpuAvailable: true, fanAvailable: true)
            == [.download, .upload, .cpu, .memory, .fan])
}

private actor SuspendedGPUProvider: SystemMetricsProviding {
    let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<GPUMetrics?, Never>?
    private var samples = 0
    func gpu() async -> GPUMetrics? {
        samples += 1
        if samples > 1 { return .init(percent: 42) }
        return await withCheckedContinuation {
            continuation = $0
            entered.continuation.yield(())
        }
    }
    func release() { continuation?.resume(returning: .init(percent: 99)); continuation = nil }
    func cpu() -> CPUCounter? { nil }
    func network() -> [NetworkCounter]? { nil }
    func memory() -> MemoryMetrics? { nil }
    func fan() -> FanMetrics? { nil }
    func reset() {}
}

@MainActor @Test func gpuCancelledSampleCannotPublishAfterCollapseOrRestart() async {
    let provider = SuspendedGPUProvider(), scheduler = ManualSystemScheduler()
    var delivered: [Double] = []
    let monitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) {
        if let gpu = $0.gpu { delivered.append(gpu.percent) }
    }
    let options = SystemMetricOptions(network: false, fan: false, memory: false, cpu: false)
    monitor.update(expanded: true, options: options)
    var entered = provider.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    monitor.update(expanded: false, options: options)
    await provider.release()
    monitor.update(expanded: true, options: options)
    await scheduler.waitForDeadlines([1])
    #expect(delivered == [42])
    monitor.stop()
    await scheduler.waitForDeadlines([])
}
