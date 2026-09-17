import Foundation

public enum SystemTopBandItem: String, CaseIterable, Sendable {
    case download, upload, cpu, gpu, memory, fan

    public var isNetwork: Bool { self == .download || self == .upload }
}

public enum SystemTopBandLevel: Int, CaseIterable, Sendable {
    case full = 1, overflow, textOnly, compactNetwork, downloadOnly, hideHardware
    public var showsIcons: Bool { rawValue < Self.textOnly.rawValue }
    public var compactRates: Bool { rawValue >= Self.compactNetwork.rawValue }
}

public enum SystemTopBandCapacity: Sendable, Equatable {
    case wings(left: CGFloat, right: CGFloat)
    case row(width: CGFloat)
}

public struct SystemTopBandRegion: Sendable, Equatable {
    public let side: SystemTopBandPlacement.Side
    public let x: CGFloat
    public let width: CGFloat
}

/// Worst-case widths, measured with the same font and item views used for display.
public struct SystemTopBandWidths: Sendable, Equatable {
    public var full: [SystemTopBandItem: CGFloat]
    public var textOnly: [SystemTopBandItem: CGFloat]
    public var compact: [SystemTopBandItem: CGFloat]
    public init(full: [SystemTopBandItem: CGFloat], textOnly: [SystemTopBandItem: CGFloat],
                compact: [SystemTopBandItem: CGFloat]) {
        self.full = full; self.textOnly = textOnly; self.compact = compact
    }
    public func width(of item: SystemTopBandItem, at level: SystemTopBandLevel) -> CGFloat {
        let widths = level.showsIcons ? full : level.compactRates ? compact : textOnly
        guard let value = widths[item], value.isFinite, value >= 0 else { return .infinity }
        return value
    }
}

public struct SystemTopBandPlacement: Sendable, Equatable {
    public enum Side: Sendable { case left, right, row }
    public let item: SystemTopBandItem
    public let side: Side
    /// Panel-relative for plan(panelWidth:...), region-relative for plan(capacity:...).
    public let x: CGFloat
    public let width: CGFloat
}

public struct SystemTopBandPlan: Sendable, Equatable {
    public let level: SystemTopBandLevel
    public let placements: [SystemTopBandPlacement]
    public let hidden: [SystemTopBandItem]
    public func items(on side: SystemTopBandPlacement.Side) -> [SystemTopBandItem] {
        placements.filter { $0.side == side }.map(\.item)
    }
}

public enum SystemTopBandLayout {
    public static let spacing: CGFloat = 6

    /// The outer edge follows the cards; only the inner edge uses the notch safety inset.
    public static func regions(panelWidth: CGFloat, notchWidth: CGFloat?, notchSafetyInset: CGFloat,
                               outerInset: CGFloat = IslandLayout.expandedContentInset) -> [SystemTopBandRegion] {
        guard panelWidth.isFinite, panelWidth >= 0, outerInset.isFinite, outerInset >= 0 else { return [] }
        if let notchWidth {
            guard notchWidth.isFinite, notchWidth >= 0, notchWidth <= panelWidth,
                  notchSafetyInset.isFinite, notchSafetyInset >= 0 else { return [] }
            let wing = (panelWidth - notchWidth) / 2
            let width = max(0, wing - notchSafetyInset - outerInset)
            return [.init(side: .left, x: outerInset, width: width),
                    .init(side: .right, x: wing + notchWidth + notchSafetyInset, width: width)]
        }
        return [.init(side: .row, x: outerInset, width: max(0, panelWidth - 2 * outerInset))]
    }

    /// Shared geometry and capacity calculation for rendering, tests, and snapshot guides.
    public static func plan(panelWidth: CGFloat, notchWidth: CGFloat?, notchSafetyInset: CGFloat,
                            outerInset: CGFloat = IslandLayout.expandedContentInset, widths: SystemTopBandWidths,
                            options: SystemMetricOptions, gpuAvailable: Bool, fanAvailable: Bool) -> SystemTopBandPlan {
        let regions = regions(panelWidth: panelWidth, notchWidth: notchWidth,
                              notchSafetyInset: notchSafetyInset, outerInset: outerInset)
        let capacity: SystemTopBandCapacity = notchWidth == nil
            ? .row(width: regions.first?.width ?? 0)
            : .wings(left: regions.first?.width ?? 0, right: regions.last?.width ?? 0)
        let local = plan(capacity: capacity, widths: widths, options: options,
                         gpuAvailable: gpuAvailable, fanAvailable: fanAvailable)
        let placements = local.placements.compactMap { placement -> SystemTopBandPlacement? in
            guard let region = regions.first(where: { $0.side == placement.side }) else { return nil }
            return .init(item: placement.item, side: placement.side, x: region.x + placement.x, width: placement.width)
        }
        return .init(level: local.level, placements: placements, hidden: local.hidden)
    }

    public static func enabledItems(options: SystemMetricOptions, gpuAvailable: Bool,
                                    fanAvailable: Bool) -> [SystemTopBandItem] {
        var items: [SystemTopBandItem] = options.network ? [.download, .upload] : []
        if options.cpu { items.append(.cpu) }
        if options.gpu && gpuAvailable { items.append(.gpu) }
        if options.memory { items.append(.memory) }
        if options.fan && fanAvailable { items.append(.fan) }
        return items
    }

    /// No live values or UI APIs: levels are decided exclusively from maximum widths and availability.
    public static func plan(capacity: SystemTopBandCapacity, widths: SystemTopBandWidths,
                            options: SystemMetricOptions, gpuAvailable: Bool, fanAvailable: Bool) -> SystemTopBandPlan {
        let enabled = enabledItems(options: options, gpuAvailable: gpuAvailable, fanAvailable: fanAvailable)
        let network = enabled.filter(\.isNetwork), hardware = enabled.filter { !$0.isNetwork }
        for level in SystemTopBandLevel.allCases where level != .hideHardware {
            if case .row = capacity, level == .overflow { continue }
            let rates = level == .downloadOnly ? network.filter { $0 == .download } : network
            if let placements = fit(rates: rates, hardware: hardware, capacity: capacity, widths: widths, level: level) {
                return result(level, placements, enabled)
            }
        }
        // Only after every complete-hardware option fails may lower priorities disappear.
        let rates = network.filter { $0 == .download }
        for count in (0..<hardware.count).reversed() {
            if let placements = fit(rates: rates, hardware: Array(hardware.prefix(count)),
                                    capacity: capacity, widths: widths, level: .hideHardware) {
                return result(.hideHardware, placements, enabled)
            }
        }
        // Even the download might exceed an exceptionally narrow safe area.
        return result(.hideHardware, [], enabled)
    }

    private static func result(_ level: SystemTopBandLevel, _ placements: [SystemTopBandPlacement],
                               _ enabled: [SystemTopBandItem]) -> SystemTopBandPlan {
        .init(level: level, placements: placements, hidden: enabled.filter { item in
            !placements.contains { $0.item == item }
        })
    }

    private static func fit(rates: [SystemTopBandItem], hardware: [SystemTopBandItem],
                            capacity: SystemTopBandCapacity, widths: SystemTopBandWidths,
                            level: SystemTopBandLevel) -> [SystemTopBandPlacement]? {
        func length(_ items: [SystemTopBandItem]) -> CGFloat {
            items.reduce(0) { $0 + widths.width(of: $1, at: level) } + CGFloat(max(0, items.count - 1)) * spacing
        }
        func place(_ items: [SystemTopBandItem], side: SystemTopBandPlacement.Side,
                   start: CGFloat = 0, gap: CGFloat = spacing) -> [SystemTopBandPlacement] {
            var x = start
            return items.map { item in
                let width = widths.width(of: item, at: level)
                defer { x += width + gap }
                return .init(item: item, side: side, x: x, width: width)
            }
        }
        switch capacity {
        case let .row(width):
            let items = rates + hardware
            guard width.isFinite, length(items) <= max(0, width) else { return nil }
            let total = items.reduce(0) { $0 + widths.width(of: $1, at: level) }
            let gap = items.count > 1 ? (max(0, width) - total) / CGFloat(items.count - 1) : 0
            return place(items, side: .row, gap: gap)
        case let .wings(left, right):
            guard left.isFinite, right.isFinite else { return nil }
            // Move fan, then memory, then GPU, keeping CPU on the right and display order intact.
            let movable = hardware.filter { $0 != .cpu }.count
            let maxMoved = level == .full ? 0 : movable
            for moved in 0...maxMoved {
                let leftItems = rates + hardware.suffix(moved)
                let rightItems = Array(hardware.dropLast(moved))
                guard length(leftItems) <= max(0, left), length(rightItems) <= max(0, right) else { continue }
                return place(leftItems, side: .left)
                    + place(rightItems, side: .right, start: max(0, right) - length(rightItems))
            }
            return nil
        }
    }
}
