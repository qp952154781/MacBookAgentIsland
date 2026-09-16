import Foundation

public enum ExpansionMethod: String, Sendable, CaseIterable {
    case hover, click
    public var label: String { self == .hover ? "悬停" : "点击" }
}

/// User-driven expansion state. Data updates never enter this state machine.
public struct IslandInteraction: Sendable, Equatable {
    public private(set) var method: ExpansionMethod = .hover
    public private(set) var pinned = false
    public private(set) var hovered = false
    public private(set) var hoverExpanded = false
    private var suppressHoverUntilExit = false
    public var expanded: Bool { pinned || hoverExpanded }
    public init() {}

    public mutating func setMethod(_ value: ExpansionMethod) {
        guard value != method else { return }
        method = value
        // Changing a preference cannot open the island. Preserve only explicit pins.
        hoverExpanded = false
        suppressHoverUntilExit = hovered
    }
    public mutating func setHovered(_ inside: Bool) {
        hovered = inside
        if !inside { suppressHoverUntilExit = false }
    }
    public mutating func settleHover() {
        guard method == .hover else { return }
        hoverExpanded = hovered && !suppressHoverUntilExit
    }
    public mutating func click() {
        if pinned {
            pinned = false
            hoverExpanded = false
            suppressHoverUntilExit = true
        } else { pinned = true }
    }
    public mutating func clickOutside() {
        pinned = false
        hoverExpanded = false
        suppressHoverUntilExit = hovered
    }
}
