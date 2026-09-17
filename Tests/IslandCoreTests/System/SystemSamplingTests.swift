import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

actor ManualSystemScheduler: SystemSamplingScheduler {
    private var instant = 0.0
    private var waiters: [UUID: (Double, CheckedContinuation<Void, any Error>)] = [:]
    private var observers: [([Double], CheckedContinuation<Void, Never>)] = []
    func now() -> Double { instant }
    func sleep(until deadline: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if deadline <= instant { continuation.resume() }
                else { waiters[id] = (deadline, continuation) }
                notify()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
        notify()
    }
    func advance(to time: Double) {
        instant = time
        let ready = waiters.filter { $0.value.0 <= time }
        for id in ready.keys { waiters[id] = nil }
        for waiter in ready.values { waiter.1.resume() }
        notify()
    }
    func waitForDeadlines(_ deadlines: [Double]) async {
        if waiters.values.map(\.0).sorted() == deadlines.sorted() { return }
        await withCheckedContinuation { observers.append((deadlines.sorted(), $0)) }
    }
    private func notify() {
        let current = waiters.values.map(\.0).sorted()
        let ready = observers.filter { $0.0 == current }
        observers.removeAll { $0.0 == current }
        for observer in ready { observer.1.resume() }
    }
}

actor FakeSystemProvider: SystemMetricsProviding {
    var gpuCalls = 0
    func gpu() -> GPUMetrics? { gpuCalls += 1; return .init(percent: 31) }
    var cpuCalls = 0
    func cpu() -> CPUCounter? {
        cpuCalls += 1
        return .init(user: UInt32(cpuCalls * 10), system: UInt32(cpuCalls * 5),
                     idle: UInt32(cpuCalls * 80), nice: UInt32(cpuCalls * 5))
    }
    var networkCalls = 0
    var memoryCalls = 0
    var fanCalls = 0
    var resets = 0
    func network() -> [NetworkCounter]? {
        networkCalls += 1
        return [.init(name: "en0", received: UInt64(networkCalls * 1000), sent: UInt64(networkCalls * 100))]
    }
    func memory() -> MemoryMetrics? { memoryCalls += 1; return .init(usedBytes: 72, totalBytes: 100) }
    func fan() -> FanMetrics? { fanCalls += 1; return nil }
    func reset() { resets += 1 }
}

@MainActor @Test func systemSamplingFollowsExpansionAndExactCadence() async {
    let scheduler = ManualSystemScheduler(), provider = FakeSystemProvider()
    var latest = SystemMetrics()
    let monitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) { latest = $0 }
    monitor.update(expanded: false, options: .init(cpu: false, gpu: false))
    #expect(await provider.networkCalls == 0)
    monitor.update(expanded: true, options: .init(cpu: false, gpu: false))
    await scheduler.waitForDeadlines([0.5, 2])
    #expect(latest.network == nil)
    #expect(latest.memory?.percent == 72)
    #expect(await provider.networkCalls == 1)
    #expect(await provider.memoryCalls == 1)
    #expect(await provider.fanCalls == 1)
    await scheduler.advance(to: 0.5)
    await scheduler.waitForDeadlines([1.5, 2])
    #expect(latest.network?.downBytesPerSec == 2000)
    await scheduler.advance(to: 1.5)
    await scheduler.waitForDeadlines([2.5, 2])
    #expect(latest.network?.downBytesPerSec == 1000)
    #expect(await provider.memoryCalls == 1)
    await scheduler.advance(to: 2)
    await scheduler.waitForDeadlines([2.5, 4])
    #expect(await provider.memoryCalls == 2)
    #expect(await provider.fanCalls == 2)
    monitor.update(expanded: false, options: .init(cpu: false, gpu: false))
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 100)
    #expect(await provider.networkCalls == 3)
    #expect(await provider.memoryCalls == 2)
    #expect(latest.network == nil)
    monitor.update(expanded: true, options: .init(cpu: false, gpu: false))
    await scheduler.waitForDeadlines([100.5, 102])
    #expect(latest.network == nil)
    #expect(await provider.resets == 0)
    monitor.stop()
    await scheduler.waitForDeadlines([])
}

@MainActor @Test func samplingSettingsWakeAndRapidRestart() async {
    let scheduler = ManualSystemScheduler(), provider = FakeSystemProvider()
    let monitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) { _ in }
    monitor.update(expanded: true, options: .init(network: true, fan: false, memory: false, cpu: false, gpu: false))
    await scheduler.waitForDeadlines([0.5])
    #expect(await provider.memoryCalls == 0)
    #expect(await provider.fanCalls == 0)
    monitor.update(expanded: true, options: .init(network: false, fan: false, memory: false, cpu: false, gpu: false))
    await scheduler.waitForDeadlines([])
    monitor.update(expanded: true, options: .init(network: false, fan: false, memory: true, cpu: false, gpu: false))
    await scheduler.waitForDeadlines([2])
    #expect(await provider.networkCalls == 1)
    #expect(await provider.resets == 2)
    monitor.update(expanded: true, options: .init(network: false, fan: false, memory: true, cpu: false, gpu: false), reset: true)
    // A following restart awaits the wake reset even if its own predecessor is cancelled.
    monitor.update(expanded: false, options: .init(network: false, fan: false, memory: true, cpu: false, gpu: false))
    monitor.update(expanded: true, options: .init(network: false, fan: false, memory: true, cpu: false, gpu: false))
    // Advancing beyond the old deadline disambiguates the old sleeper from the new loop.
    await scheduler.advance(to: 10)
    await scheduler.waitForDeadlines([12])
    #expect(await provider.resets == 3)
    #expect(await provider.fanCalls == 0)
    monitor.stop()
    await scheduler.waitForDeadlines([])
}

@MainActor @Test func viewModelStopsSystemSamplingWhenHiddenOrClosed() async {
    let provider = FakeSystemProvider(), scheduler = ManualSystemScheduler()
    let store = IslandStore()
    store.systemMetricOptions.cpu = false
    store.systemMetricOptions.gpu = false
    let model = IslandViewModel(store: store)
    model.enableSystemMetrics(provider: provider, scheduler: scheduler)
    #expect(await provider.networkCalls == 0)
    model.togglePinned()
    await scheduler.waitForDeadlines([0.5, 2])
    #expect(model.mode == .expanded)
    model.animationsVisible = false
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 10)
    #expect(await provider.networkCalls == 1)
    model.animationsVisible = true
    await scheduler.waitForDeadlines([10.5, 12])
    model.clickedOutside()
    await scheduler.waitForDeadlines([])
    #expect(model.mode == .collapsed)
    await scheduler.advance(to: 20)
    model.togglePinned()
    await scheduler.waitForDeadlines([20.5, 22])
    model.stop()
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 100)
    #expect(await provider.networkCalls == 3)
    #expect(await provider.memoryCalls == 3)
}

private actor SuspendedSystemProvider: SystemMetricsProviding {
    let entered = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<[NetworkCounter]?, Never>?
    private var calls = 0
    func network() async -> [NetworkCounter]? {
        calls += 1
        if calls > 1 { return [.init(name: "en0", received: 9999, sent: 9999)] }
        return await withCheckedContinuation {
            continuation = $0
            entered.continuation.yield(())
        }
    }
    func release() {
        continuation?.resume(returning: [.init(name: "en0", received: 1000, sent: 1000)])
        continuation = nil
    }
    func gpu() -> GPUMetrics? { nil }
    func cpu() -> CPUCounter? { nil }
    func memory() -> MemoryMetrics? { nil }
    func fan() -> FanMetrics? { nil }
    func reset() {}
}

@MainActor @Test func cancelledInFlightSampleCannotPublishIntoNextExpansion() async {
    let scheduler = ManualSystemScheduler(), provider = SuspendedSystemProvider()
    var latest = SystemMetrics()
    var deliveries = 0
    let monitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) { latest = $0; deliveries += 1 }
    let options = SystemMetricOptions(network: true, fan: false, memory: false, cpu: false, gpu: false)
    monitor.update(expanded: true, options: options)
    var entered = provider.entered.stream.makeAsyncIterator()
    _ = await entered.next()
    monitor.update(expanded: false, options: options)
    let afterCollapse = deliveries
    await provider.release()
    // The next loop awaits the cancelled predecessor, establishing completion without a wall-clock wait.
    monitor.update(expanded: true, options: options)
    await scheduler.waitForDeadlines([0.5])
    #expect(deliveries == afterCollapse + 2) // Reset + new baseline, no old delivery.
    #expect(latest.network == nil)
    await scheduler.advance(to: 0.5)
    await scheduler.waitForDeadlines([1.5])
    #expect(latest.network?.downBytesPerSec == 0)
    monitor.stop()
    await scheduler.waitForDeadlines([])
}
