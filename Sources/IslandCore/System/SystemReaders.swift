import Foundation
import Darwin

public struct NetworkCounter: Sendable, Equatable {
    public let name: String
    public let received: UInt64
    public let sent: UInt64
    public init(name: String, received: UInt64, sent: UInt64) {
        self.name = name; self.received = received; self.sent = sent
    }
}

public struct NetworkSample: Sendable {
    public let time: Double
    public let counters: [NetworkCounter]
    public init(time: Double, counters: [NetworkCounter]) { self.time = time; self.counters = counters }
}

public struct NetworkDifferencer: Sendable {
    private var previous: NetworkSample?
    public init() {}
    public mutating func rate(for sample: NetworkSample) -> NetworkRate? {
        defer { previous = sample }
        guard let previous, sample.time > previous.time else { return nil }
        var down = 0.0, up = 0.0
        let current = sample.counters.filter { NetworkReader.includes($0.name) }
        for counter in current {
            // New/disappeared interfaces must not turn cumulative counters into a speed spike.
            guard let old = previous.counters.first(where: { $0.name == counter.name }) else { continue }
            down += Double(counter.received &- old.received)
            up += Double(counter.sent &- old.sent)
        }
        let elapsed = sample.time - previous.time
        return .init(downBytesPerSec: down / elapsed, upBytesPerSec: up / elapsed,
                     interfaces: current.map(\.name).sorted())
    }
}

public enum NetworkReader {
    public static func includes(_ name: String) -> Bool { name.hasPrefix("en") }
    static func parse(_ data: Data, nameForIndex: (UInt32) -> String?) -> [NetworkCounter] {
        data.withUnsafeBytes { bytes in
            var offset = 0, result: [NetworkCounter] = []
            while offset <= bytes.count - 4 {
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset else { break }
                let version = bytes[offset + 2], type = bytes[offset + 3]
                if version == RTM_VERSION, type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = nameForIndex(UInt32(header.ifm_index)), includes(name) {
                        result.append(.init(name: name, received: header.ifm_data.ifi_ibytes, sent: header.ifm_data.ifi_obytes))
                    }
                }
                offset += length
            }
            return result
        }
    }
    public static func sample() -> [NetworkCounter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 16 * 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0, size <= data.count else { return nil }
        data.count = size
        return parse(data) { index in
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(index, &name) != nil else { return nil }
            return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}

public enum MemoryReader {
    public static func sample() -> MemoryMetrics? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return .calculate(internalPages: UInt64(info.internal_page_count), purgeable: UInt64(info.purgeable_count),
                          wired: UInt64(info.wire_count), compressed: UInt64(info.compressor_page_count),
                          pageSize: UInt64(pageSize), total: ProcessInfo.processInfo.physicalMemory)
    }
}

public protocol SystemMetricsProviding: Sendable {
    func cpu() async -> CPUCounter?
    func network() async -> [NetworkCounter]?
    func memory() async -> MemoryMetrics?
    func fan() async -> FanMetrics?
    func reset() async
}

public actor LiveSystemMetricsProvider: SystemMetricsProviding {
    private let fanReader: FanReader
    public init(smc: any SMCReading = AppleSMCReader()) { fanReader = FanReader(smc: smc) }
    public func cpu() -> CPUCounter? { Task.isCancelled ? nil : CPUReader.sample() }
    public func network() -> [NetworkCounter]? { Task.isCancelled ? nil : NetworkReader.sample() }
    public func memory() -> MemoryMetrics? { Task.isCancelled ? nil : MemoryReader.sample() }
    public func fan() async -> FanMetrics? { await fanReader.sample() }
    public func reset() async { await fanReader.reset() }
}
