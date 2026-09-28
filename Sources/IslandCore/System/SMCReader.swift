import Foundation
import IOKit

// AppleSMC's external method ABI: keyInfo occupies 12 bytes including its padding.
struct SMCParam {
    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var versionPadding: UInt16 = 0
    var limits: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var attributePadding: UInt8 = 0
    var keyInfoPadding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var commandPadding: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

public struct SMCValue: Sendable {
    public let type: String
    public let bytes: [UInt8]
    public init(type: String, bytes: [UInt8]) { self.type = type; self.bytes = bytes }
    public var decoded: Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "ui8 ":
            guard let first = bytes.first else { return nil }; value = Double(first)
        case "ui16", "fpe2", "sp78":
            guard bytes.count >= 2 else { return nil }
            let bits = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            value = type == "sp78" ? Double(Int16(bitPattern: bits)) / 256 : Double(bits) / (type == "fpe2" ? 4 : 1)
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            value = Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}

public protocol SMCReading: Sendable {
    func read(key: String) async -> SMCValue?
    func reset() async
}

/// Index enumeration stays inside IslandCore; the public transport API cannot issue commands.
protocol SMCKeyEnumerating: Sendable {
    func keyCount() async -> Int?
    func key(at index: Int) async -> String?
}

/// This gate is checked immediately before every IOKit call. No caller supplies a command.
enum SMCReadGate {
    static func allowsKey(_ key: String) -> Bool {
        if key == "#KEY" || key == "FNum" { return true }
        if (0..<10).contains(where: { key == "F\($0)Ac" || key == "F\($0)Mn" || key == "F\($0)Mx" }) { return true }
        let bytes = Array(key.utf8)
        return bytes.count == 4 && bytes[0] == 84 && bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
    static func allows(command: UInt8, key: UInt32) -> Bool {
        switch command {
        case 5, 9: return allowsKey(String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: key >> ((3 - $0) * 8)) }, encoding: .ascii) ?? "")
        case 8: return key == 0
        default: return false
        }
    }
}

public actor AppleSMCReader: SMCReading, SMCKeyEnumerating {
    private var connection: io_connect_t = 0
    private var failed = false
    public init() {}
    deinit { if connection != 0 { IOServiceClose(connection) } }

    public func reset() {
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        failed = false
    }
    public func read(key: String) -> SMCValue? {
        guard SMCReadGate.allowsKey(key), !failed, !Task.isCancelled, open() else { return nil }
        var request = SMCParam()
        request.key = key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
        request.command = 9
        // A missing key is normal during Intel fallback discovery.
        guard let info = call(request), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        request.dataSize = info.dataSize
        request.command = 5
        // A single sensor may disappear or fail without invalidating other readings.
        guard var response = call(request) else { return nil }
        let type = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: info.dataType >> ((3 - $0) * 8)) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: &response.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValue(type: type, bytes: bytes)
    }
    func keyCount() -> Int? {
        guard let value = read(key: "#KEY"), value.type == "ui32", let count = value.decoded,
              count >= 0, count <= 100_000 else { return nil }
        return Int(count)
    }
    func key(at index: Int) -> String? {
        guard index >= 0, index < 100_000, !failed, !Task.isCancelled, open() else { return nil }
        var request = SMCParam()
        request.command = 8
        request.data32 = UInt32(index)
        guard let response = call(request) else { return nil }
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: response.key >> ((3 - $0) * 8)) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
    private func open() -> Bool {
        guard MemoryLayout<SMCParam>.size == 80 else { return false }
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { failed = true; return false }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            connection = 0; failed = true; return false
        }
        return true
    }
    private func call(_ parameter: SMCParam) -> SMCParam? {
        guard !Task.isCancelled, SMCReadGate.allows(command: parameter.command, key: parameter.key) else { return nil }
        var input = parameter, output = SMCParam(), size = MemoryLayout<SMCParam>.size
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        return result == KERN_SUCCESS && size == 80 && output.result == 0 ? output : nil
    }
}

public actor FanReader {
    private let smc: any SMCReading
    private var failed = false
    private var generation = 0
    public init(smc: any SMCReading = AppleSMCReader()) { self.smc = smc }
    public func reset() async { generation += 1; failed = false; await smc.reset() }
    public func sample() async -> FanMetrics? {
        guard !failed, !Task.isCancelled else { return nil }
        let token = generation
        guard let count = await smc.read(key: "FNum")?.decoded, count > 0, count <= 10, count.rounded() == count else {
            if !Task.isCancelled, token == generation { failed = true }; return nil
        }
        var fans: [FanReading] = []
        for index in 0..<Int(count) {
            guard !Task.isCancelled, token == generation else { return nil }
            let rpm = await smc.read(key: "F\(index)Ac")?.decoded
            let min = await smc.read(key: "F\(index)Mn")?.decoded
            let max = await smc.read(key: "F\(index)Mx")?.decoded
            guard let rpm, let min, let max, rpm >= 0, min >= 0, max > 0,
                  rpm <= Double(UInt32.max), min <= max else {
                if !Task.isCancelled, token == generation { failed = true }; return nil
            }
            fans.append(.init(index: index, rpm: rpm, minRPM: min, maxRPM: max))
        }
        guard !Task.isCancelled, token == generation else { return nil }
        return FanMetrics(fans: fans)
    }
}
