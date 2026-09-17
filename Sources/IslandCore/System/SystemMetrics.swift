import Foundation

public struct SystemMetricOptions: Sendable, Equatable {
    public var gpu: Bool
    public var cpu: Bool
    public var network: Bool
    public var fan: Bool
    public var memory: Bool
    public var enabled: Bool { cpu || gpu || network || fan || memory }
    public init(network: Bool = true, fan: Bool = true, memory: Bool = true, cpu: Bool = true, gpu: Bool = true) {
        self.network = network; self.fan = fan; self.memory = memory; self.cpu = cpu; self.gpu = gpu
    }
}

public struct NetworkRate: Sendable, Equatable, Encodable {
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double
    public let interfaces: [String]
    public init(downBytesPerSec: Double, upBytesPerSec: Double, interfaces: [String]) {
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec; self.interfaces = interfaces
    }
}

public struct FanReading: Sendable, Equatable, Encodable {
    public let index: Int
    public let rpm: Double
    public let minRPM: Double
    public let maxRPM: Double
    public var warning: Bool { maxRPM > 0 && rpm >= maxRPM * 0.8 }
    public var text: String { rpm == 0 ? "风扇 静止" : "风扇 \(Int(rpm.rounded()))" }
    public init(index: Int, rpm: Double, minRPM: Double, maxRPM: Double) {
        self.index = index; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM
    }
}

public struct FanMetrics: Sendable, Equatable, Encodable {
    public let fans: [FanReading]
    public var count: Int { fans.count }
    public init(fans: [FanReading]) { self.fans = fans }
    enum CodingKeys: String, CodingKey { case count, fans }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(count, forKey: .count); try values.encode(fans, forKey: .fans)
    }
}

public struct MemoryMetrics: Sendable, Equatable, Encodable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public var percent: Double { totalBytes == 0 ? 0 : min(100, Double(usedBytes) / Double(totalBytes) * 100) }
    public var text: String { "内存 \(Int(percent.rounded()))%" }
    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes; self.totalBytes = totalBytes
    }
    public static func calculate(internalPages: UInt64, purgeable: UInt64, wired: UInt64,
                                 compressed: UInt64, pageSize: UInt64, total: UInt64) -> Self {
        let pages = Double(internalPages >= purgeable ? internalPages - purgeable : 0) + Double(wired) + Double(compressed)
        let bytes = min(Double(total), pages * Double(pageSize))
        // VM counters are kernel supplied; clamp before conversion, including the UInt64 upper edge.
        return .init(usedBytes: bytes >= Double(total) ? total : UInt64(max(0, bytes)), totalBytes: total)
    }
    enum CodingKeys: String, CodingKey { case usedBytes, totalBytes, percent }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(usedBytes, forKey: .usedBytes); try values.encode(totalBytes, forKey: .totalBytes)
        try values.encode(percent, forKey: .percent)
    }
}

public struct SystemMetrics: Sendable, Equatable, Encodable {
    public var gpu: GPUMetrics?
    public var cpu: CPUMetrics?
    public var network: NetworkRate?
    public var fan: FanMetrics?
    public var memory: MemoryMetrics?
    public init(network: NetworkRate? = nil, fan: FanMetrics? = nil, memory: MemoryMetrics? = nil, cpu: CPUMetrics? = nil, gpu: GPUMetrics? = nil) {
        self.network = network; self.fan = fan; self.memory = memory; self.cpu = cpu; self.gpu = gpu
    }
    enum CodingKeys: String, CodingKey { case network, fan, memory, cpu, gpu }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(network, forKey: .network); try values.encode(fan, forKey: .fan)
        try values.encode(memory, forKey: .memory)
        try values.encode(cpu, forKey: .cpu)
        try values.encode(gpu, forKey: .gpu)
    }
}

public enum SystemMetricFormat {
    public static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        guard bytes >= 1024 else { return "0 KB/s" }
        let units = ["KB/s", "MB/s", "GB/s"]
        var value = bytes / 1024, index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[index])
    }
}
