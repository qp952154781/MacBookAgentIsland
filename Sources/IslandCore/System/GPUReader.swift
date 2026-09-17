import Foundation
import IOKit

public struct GPUMetrics: Sendable, Equatable, Encodable {
    public let percent: Double
    public var text: String { "\(Int(percent.rounded()))%" }
    public init(percent: Double) {
        self.percent = percent.isFinite ? min(100, max(0, percent)) : 0
    }

    /// Only device utilization represents the whole accelerator. Booleans are not counters.
    public static func parse(_ statistics: [[String: Any]]) -> Self? {
        let values = statistics.compactMap { dictionary -> Double? in
            guard let number = dictionary["Device Utilization %"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        return values.max().map { Self(percent: $0) }
    }
}

public protocol GPUReading: Sendable {
    func sample() async -> GPUMetrics?
    func reset() async
}

/// Handle ownership stays on the reader actor; closures also allow synthetic registry tests.
struct GPUServiceCache: Sendable {
    private(set) var services: [UInt32] = []
    private var nextMatchTime = 0.0

    mutating func sample(at time: Double, match: () -> [UInt32],
                         read: (UInt32) -> [String: Any]?, release: (UInt32) -> Void) -> GPUMetrics? {
        if services.isEmpty {
            guard time >= nextMatchTime else { return nil }
            services = match()
            // Avoid traversing the registry every second on unsupported or unavailable systems.
            nextMatchTime = time + 30
        }
        guard !services.isEmpty else { return nil }
        let statistics = services.compactMap(read)
        if statistics.count != services.count {
            // Retry matching on a later sample. Do not retain invalid registry handles.
            services.forEach(release)
            services = []
        } else {
            nextMatchTime = time
        }
        return GPUMetrics.parse(statistics)
    }

    mutating func reset(release: (UInt32) -> Void) {
        services.forEach(release)
        services = []
        nextMatchTime = 0
    }
}

/// Like AppleSMCReader, all synchronous IOKit calls run on a background actor executor.
public actor IOAcceleratorGPUReader: GPUReading {
    private var cache = GPUServiceCache()
    public init() {}
    deinit { for service in cache.services { IOObjectRelease(service) } }

    public func reset() { cache.reset { IOObjectRelease($0) } }

    public func sample() -> GPUMetrics? {
        guard !Task.isCancelled else { return nil }
        return cache.sample(at: ProcessInfo.processInfo.systemUptime, match: {
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            defer { if iterator != 0 { IOObjectRelease(iterator) } }
            guard result == KERN_SUCCESS else { return [] }
            var services: [io_service_t] = []
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                services.append(service)
            }
            return services
        }, read: { service in
            IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        }, release: { IOObjectRelease($0) })
    }
}
