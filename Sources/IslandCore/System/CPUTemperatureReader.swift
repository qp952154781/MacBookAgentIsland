import Foundation

public struct CPUTemperatureMetrics: Sendable, Equatable, Encodable {
    public let averageCelsius: Double
    public let maximumCelsius: Double
    public let keys: [String]
    public var sensorCount: Int { keys.count }
    public var text: String { "\(Int(averageCelsius.rounded()))°C" }

    public init(averageCelsius: Double, maximumCelsius: Double, keys: [String]) {
        self.averageCelsius = averageCelsius
        self.maximumCelsius = maximumCelsius
        self.keys = keys
    }
    enum CodingKeys: String, CodingKey { case averageCelsius, maximumCelsius, sensorCount, keys }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(averageCelsius, forKey: .averageCelsius)
        try values.encode(maximumCelsius, forKey: .maximumCelsius)
        try values.encode(sensorCount, forKey: .sensorCount)
        try values.encode(keys, forKey: .keys)
    }
}

public enum CPUTemperaturePlatform: Sendable, Equatable {
    case appleSilicon, intel

    public static var current: Self {
        #if arch(arm64)
        .appleSilicon
        #else
        .intel
        #endif
    }
}

public actor CPUTemperatureReader {
    private let smc: any SMCReading
    private let platform: CPUTemperaturePlatform
    private var discovered: [String]?
    private var generation = 0
    private var consecutiveFailures = 0

    public init(smc: any SMCReading = AppleSMCReader(), platform: CPUTemperaturePlatform = .current) {
        self.smc = smc
        self.platform = platform
    }

    public func reset() async {
        generation += 1
        // Rediscover on wake after repeated failures; healthy keys remain cached.
        if consecutiveFailures >= 2 { discovered = nil }
        consecutiveFailures = 0
        await smc.reset()
    }

    public func sample() async -> CPUTemperatureMetrics? {
        guard !Task.isCancelled else { return nil }
        let token = generation
        if discovered == nil {
            let keys = await discover()
            guard !Task.isCancelled, token == generation else { return nil }
            discovered = keys
        }
        guard let keys = discovered, !keys.isEmpty else { consecutiveFailures += 1; return nil }
        var readings: [(String, Double)] = []
        for key in keys {
            guard !Task.isCancelled, token == generation else { return nil }
            if let value = await smc.read(key: key),
               value.type == (platform == .intel ? "sp78" : "flt "),
               let temperature = value.decoded, (10...130).contains(temperature) {
                readings.append((key, temperature))
            }
        }
        guard !Task.isCancelled, token == generation else { return nil }
        guard !readings.isEmpty else { consecutiveFailures += 1; return nil }
        consecutiveFailures = 0
        let sum = readings.reduce(0) { $0 + $1.1 }
        return .init(averageCelsius: sum / Double(readings.count),
                     maximumCelsius: readings.map { $0.1 }.max() ?? 0,
                     keys: readings.map { $0.0 })
    }

    private func discover() async -> [String] {
        switch platform {
        case .appleSilicon:
            guard let enumerator = smc as? any SMCKeyEnumerating,
                  let count = await enumerator.keyCount(), count > 0 else { return [] }
            var keys: [String] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return [] }
                guard let key = await enumerator.key(at: index), Self.isSiliconCPUKey(key),
                      let value = await smc.read(key: key), value.type == "flt ",
                      let temperature = value.decoded, (10...130).contains(temperature) else { continue }
                keys.append(key)
            }
            return keys
        case .intel:
            for key in ["TCXC", "TC0D", "TC0E", "TC0F", "TC0P"] {
                guard !Task.isCancelled else { return [] }
                if let value = await smc.read(key: key), value.type == "sp78" { return [key] }
            }
            return []
        }
    }

    static func isSiliconCPUKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return bytes.count == 4 && bytes[0] == 84 && [112, 101, 102].contains(bytes[1])
            && bytes[2...3].allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
    }
}
