import Foundation
import IslandCore

struct DumpSystem {
    static func run(provider: any SystemMetricsProviding = LiveSystemMetricsProvider(),
                    scheduler: any SystemSamplingScheduler = LiveSystemSamplingScheduler()) async throws {
        var difference = NetworkDifferencer()
        var cpuDifference = CPUDifferencer()
        if let counters = await provider.cpu() {
            _ = cpuDifference.reading(for: counters, time: await scheduler.now())
        }
        let start = await scheduler.now()
        if let counters = await provider.network() { _ = difference.rate(for: .init(time: start, counters: counters)) }
        try await scheduler.sleep(until: start + 1)
        let end = await scheduler.now()
        let network = await provider.network().flatMap { difference.rate(for: .init(time: end, counters: $0)) }
        let counters = await provider.cpu()
        let cpuTime = await scheduler.now()
        let cpu = counters.flatMap { cpuDifference.reading(for: $0, time: cpuTime) }
        let memory = await provider.memory()
        let fan = await provider.fan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SystemMetrics(network: network, fan: fan, memory: memory, cpu: cpu))
        print(String(decoding: data, as: UTF8.self))
    }
}
