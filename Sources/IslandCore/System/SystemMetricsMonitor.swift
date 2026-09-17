import Foundation

public protocol SystemSamplingScheduler: Sendable {
    func now() async -> Double
    func sleep(until deadline: Double) async throws
}

public struct LiveSystemSamplingScheduler: SystemSamplingScheduler {
    public init() {}
    public func now() -> Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(until deadline: Double) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
    }
}

/// Owns cancellable background loops. Collapsed/disabled state has no sampling timers.
@MainActor public final class SystemMetricsMonitor {
    private let provider: any SystemMetricsProviding
    private let scheduler: any SystemSamplingScheduler
    private let receive: @MainActor @Sendable (SystemMetrics) -> Void
    private var task: Task<Void, Never>?
    private var options: SystemMetricOptions?
    private var running = false
    private var generation = 0
    private var metrics = SystemMetrics()

    public init(provider: any SystemMetricsProviding = LiveSystemMetricsProvider(),
                scheduler: any SystemSamplingScheduler = LiveSystemSamplingScheduler(),
                receive: @escaping @MainActor @Sendable (SystemMetrics) -> Void) {
        self.provider = provider; self.scheduler = scheduler; self.receive = receive
    }
    deinit { task?.cancel() }

    public func update(expanded: Bool, options: SystemMetricOptions, reset: Bool = false) {
        let shouldRun = expanded && options.enabled
        let changed = self.options != nil && self.options != options
        guard shouldRun != running || self.options != options || reset else { return }
        self.options = options; running = shouldRun
        generation += 1
        let token = generation, previous = task
        previous?.cancel()
        metrics = SystemMetrics(); receive(metrics)
        let provider = provider, scheduler = scheduler
        task = Task.detached(priority: .utility) { [weak self] in
            // Serialize restarts so cancelled readings cannot race a reset or a new baseline.
            await previous?.value
            if changed || reset { await provider.reset() }
            guard shouldRun, !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                if options.cpu {
                    group.addTask {
                        var difference = CPUDifferencer()
                        var first = true
                        while !Task.isCancelled {
                            let counters = await provider.cpu()
                            let now = await scheduler.now()
                            let cpu = counters.flatMap { difference.reading(for: $0, time: now) }
                            if counters == nil { difference = CPUDifferencer() }
                            guard !Task.isCancelled else { return }
                            await self?.publishCPU(cpu, token: token)
                            do { try await scheduler.sleep(until: now + (first ? 0.25 : 1)) } catch { return }
                            first = false
                        }
                    }
                }
                if options.gpu {
                    group.addTask {
                        while !Task.isCancelled {
                            let now = await scheduler.now()
                            let gpu = await provider.gpu()
                            guard !Task.isCancelled else { return }
                            await self?.publishGPU(gpu, token: token)
                            do { try await scheduler.sleep(until: now + 1) } catch { return }
                        }
                    }
                }
                if options.network {
                    group.addTask {
                        var difference = NetworkDifferencer()
                        var first = true
                        while !Task.isCancelled {
                            let now = await scheduler.now()
                            let counters = await provider.network()
                            let rate = counters.flatMap { difference.rate(for: .init(time: now, counters: $0)) }
                            if counters == nil { difference = NetworkDifferencer() }
                            guard !Task.isCancelled else { return }
                            await self?.publishNetwork(rate, token: token)
                            do { try await scheduler.sleep(until: now + (first ? 0.5 : 1)) } catch { return }
                            first = false
                        }
                    }
                }
                if options.memory || options.fan {
                    group.addTask {
                        while !Task.isCancelled {
                            let now = await scheduler.now()
                            let memory = options.memory ? await provider.memory() : nil
                            guard !Task.isCancelled else { return }
                            let fan = options.fan ? await provider.fan() : nil
                            guard !Task.isCancelled else { return }
                            await self?.publishHardware(memory: memory, fan: fan, token: token)
                            do { try await scheduler.sleep(until: now + 2) } catch { return }
                        }
                    }
                }
            }
        }
    }
    public func stop() {
        running = false; generation += 1; task?.cancel()
    }
    private func publishGPU(_ gpu: GPUMetrics?, token: Int) {
        guard running, token == generation else { return }
        metrics.gpu = gpu; receive(metrics)
    }
    private func publishCPU(_ cpu: CPUMetrics?, token: Int) {
        guard running, token == generation else { return }
        metrics.cpu = cpu; receive(metrics)
    }
    private func publishNetwork(_ rate: NetworkRate?, token: Int) {
        guard running, token == generation else { return }
        metrics.network = rate; receive(metrics)
    }
    private func publishHardware(memory: MemoryMetrics?, fan: FanMetrics?, token: Int) {
        guard running, token == generation else { return }
        metrics.memory = memory; metrics.fan = fan; receive(metrics)
    }
}
