import Foundation

public enum SystemHardwareMetric: String, Sendable, CaseIterable {
    case cpu, gpu, memory, fan
}

public enum SystemHardwareLayout {
    /// Prefixes preserve priority: discard fan, memory, GPU, then CPU as space shrinks.
    public static func items(options: SystemMetricOptions, metrics: SystemMetrics,
                             maximumCount: Int = 4) -> [SystemHardwareMetric] {
        var items: [SystemHardwareMetric] = []
        if options.cpu { items.append(.cpu) }
        if options.gpu, metrics.gpu != nil { items.append(.gpu) }
        if options.memory { items.append(.memory) }
        if options.fan, metrics.fan?.fans.first != nil { items.append(.fan) }
        return Array(items.prefix(max(0, maximumCount)))
    }
}
