import Foundation
import Darwin

public struct CPUCounter: Sendable, Equatable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32
    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public struct CPUMetrics: Sendable, Equatable, Encodable {
    public let percent: Double
    public let sampleIntervalMs: Double
    public var text: String { "\(Int(percent.rounded()))%" }
    public init(percent: Double, sampleIntervalMs: Double) {
        self.percent = percent.isFinite ? min(100, max(0, percent)) : 0
        self.sampleIntervalMs = sampleIntervalMs.isFinite ? max(0, sampleIntervalMs) : 0
    }
}

public struct CPUDifferencer: Sendable {
    private var previous: (counter: CPUCounter, time: Double)?
    private var lastPercent: Double?
    public init() {}
    public mutating func reading(for counter: CPUCounter, time: Double) -> CPUMetrics? {
        guard time.isFinite else { return nil }
        defer { previous = (counter, time) }
        guard let previous, time > previous.time else { return nil }
        // Wrap each 32-bit state before widening; the sum can exceed UInt32.max.
        let busy = UInt64(counter.user &- previous.counter.user)
            + UInt64(counter.system &- previous.counter.system)
            + UInt64(counter.nice &- previous.counter.nice)
        let total = busy + UInt64(counter.idle &- previous.counter.idle)
        if total > 0 { lastPercent = Double(busy) / Double(total) * 100 }
        guard let lastPercent else { return nil }
        return .init(percent: lastPercent, sampleIntervalMs: (time - previous.time) * 1000)
    }
}

public enum CPUReader {
    public static func sample() -> CPUCounter? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        let expected = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var count = expected
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count >= expected else { return nil }
        return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1,
                     idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}
