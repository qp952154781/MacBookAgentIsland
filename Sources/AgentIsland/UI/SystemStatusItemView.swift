import AppKit
import SwiftUI
import IslandCore

struct SystemStatusItemView: View {
    let item: SystemTopBandItem
    let value: String
    let level: SystemTopBandLevel

    var body: some View {
        HStack(spacing: item.isNetwork && level.compactRates ? 0 : 3) {
            if item.isNetwork || level.showsIcons { Image(systemName: symbol) }
            if !item.isNetwork { Text(label) }
            Text(value)
        }
        .font(Theme.font(10, weight: .medium)).monospacedDigit()
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch item {
        case .download: "arrow.down"
        case .upload: "arrow.up"
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .fan: "fan"
        }
    }
    private var label: String {
        switch item {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .fan: "风扇"
        case .download, .upload: ""
        }
    }
}

@MainActor enum SystemStatusSizing {
    // Measure worst-case prototypes once, not live values on each sampling tick.
    static let widths = SystemTopBandWidths(full: measure(.full), textOnly: measure(.textOnly),
                                           compact: measure(.compactNetwork))

    private static func measure(_ level: SystemTopBandLevel) -> [SystemTopBandItem: CGFloat] {
        Dictionary(uniqueKeysWithValues: SystemTopBandItem.allCases.map { item in
            let prototypes = item.isNetwork ? SystemTopBandFormat.ratePrototypes(compact: level.compactRates)
                : item == .fan ? SystemTopBandFormat.fanPrototypes : SystemTopBandFormat.percentagePrototypes
            let width = prototypes.map { value in
                NSHostingView(rootView: SystemStatusItemView(item: item, value: value, level: level)).fittingSize.width
            }.max() ?? 0
            return (item, ceil(width))
        })
    }
}
