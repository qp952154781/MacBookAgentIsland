import Foundation

/// Presentation policy only; stored quota values and their encoding remain usage-based.
public enum QuotaDisplayMode: String, Sendable, CaseIterable {
    case remaining, used

    public var label: String { self == .remaining ? "剩余" : "已用" }

    public func headline(_ snapshot: QuotaSnapshot) -> QuotaWindow? {
        if self == .remaining && snapshot.agent == .claude {
            return snapshot.session ?? snapshot.weekly
        }
        return snapshot.headline
    }

    public func fallbackNote(_ snapshot: QuotaSnapshot) -> String? {
        guard self == .remaining, snapshot.agent == .claude, snapshot.session == nil else { return nil }
        return snapshot.weekly == nil ? "无 5 小时或本周额度" : "无 5 小时额度，收起态显示本周剩余"
    }

    public func percent(_ window: QuotaWindow?, expanded: Bool = false) -> String {
        if let text = window?.valueText { return text }
        guard let window, window.usedPercent.isFinite else { return "--" }
        let value = self == .remaining ? floor(window.remainingPercent) : window.usedPercent
        return (self == .remaining && expanded ? "剩 " : "") + String(format: "%.0f%%", value)
    }

    public func fillFraction(_ window: QuotaWindow) -> Double {
        guard window.usedPercent.isFinite else { return 0 }
        return self == .remaining ? window.remainingPercent / 100 : min(1, max(0, window.usedPercent / 100))
    }

    public func paceFraction(_ window: QuotaWindow, now: Date) -> Double? {
        window.elapsedFraction(now: now).map { self == .remaining ? 1 - $0 : $0 }
    }

    public func isAheadOfPace(_ window: QuotaWindow, now: Date) -> Bool {
        guard window.usedPercent.isFinite, let pace = paceFraction(window, now: now) else { return false }
        return self == .remaining ? fillFraction(window) < pace : fillFraction(window) > pace
    }
}

public extension QuotaWindow {
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}
