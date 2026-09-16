import Foundation

/// Allows settings persistence tests without touching the host's preferences.
@MainActor public protocol AppSettingsDefaults {
    func string(forKey defaultName: String) -> String?
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: AppSettingsDefaults {}

@MainActor @Observable public final class AppSettings {
    public var showCPU: Bool { didSet { persist() } }
    public var showNetwork: Bool { didSet { persist() } }
    public var showFan: Bool { didSet { persist() } }
    public var showMemory: Bool { didSet { persist() } }
    public var systemMetricOptions: SystemMetricOptions {
        .init(network: showNetwork, fan: showFan, memory: showMemory, cpu: showCPU)
    }
    public var expansionMethod: ExpansionMethod { didSet { persist() } }
    public var quotaDisplayMode: QuotaDisplayMode { didSet { persist() } }
    public var refreshInterval: Int { didSet { persist() } }
    public var warningThreshold: Double { didSet { persist() } }
    public var criticalThreshold: Double { didSet { persist() } }
    public var wingWidth: Double { didSet { persist() } }
    public var useMainScreen: Bool { didSet { persist() } }
    public var showInFullscreen: Bool { didSet { persist() } }
    public var launchAtLogin: Bool { didSet { persist() } }
    public var activeMinutes: Int { didSet { persist() } }
    public var sessionListLayout: SessionListLayoutMode { didSet { persist() } }
    @ObservationIgnored private let defaults: (any AppSettingsDefaults)?
    @ObservationIgnored public var onChange: (() -> Void)?

    /// Nil defaults keeps snapshot and fixture settings entirely in memory.
    public init(defaults: (any AppSettingsDefaults)? = nil) {
        self.defaults = defaults
        sessionListLayout = defaults?.string(forKey: "sessionListLayout").flatMap(SessionListLayoutMode.init(rawValue:)) ?? .automatic
        expansionMethod = defaults?.string(forKey: "expansionMethod").flatMap(ExpansionMethod.init(rawValue:)) ?? .hover
        quotaDisplayMode = defaults?.string(forKey: "quotaDisplayMode").flatMap(QuotaDisplayMode.init(rawValue:)) ?? .remaining
        func number(_ key: String, _ fallback: Double) -> Double {
            let value = (defaults?.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
            return value.isFinite ? value : fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults?.object(forKey: key) as? Bool ?? fallback }
        showCPU = flag("showCPU", true)
        showNetwork = flag("showNetwork", true)
        showFan = flag("showFan", true)
        showMemory = flag("showMemory", true)
        let interval = number("refreshInterval", 120)
        refreshInterval = [30, 60, 120, 300].contains(interval) ? Int(interval) : 120
        let warning = min(98, max(1, number("warningThreshold", 70)))
        warningThreshold = warning
        criticalThreshold = min(100, max(warning + 1, number("criticalThreshold", 90)))
        wingWidth = min(100, max(60, number("wingWidth", 76)))
        useMainScreen = flag("useMainScreen", false)
        showInFullscreen = flag("showInFullscreen", false)
        launchAtLogin = flag("launchAtLogin", false)
        let active = number("activeMinutes", 30)
        activeMinutes = [15, 30, 60].contains(active) ? Int(active) : 30
    }
    private func persist() {
        let values: [String: Any] = ["showCPU": showCPU, "showNetwork": showNetwork, "showFan": showFan, "showMemory": showMemory, "refreshInterval": refreshInterval, "warningThreshold": warningThreshold,
            "criticalThreshold": criticalThreshold, "wingWidth": wingWidth, "useMainScreen": useMainScreen,
            "showInFullscreen": showInFullscreen, "launchAtLogin": launchAtLogin, "activeMinutes": activeMinutes,
            "expansionMethod": expansionMethod.rawValue, "quotaDisplayMode": quotaDisplayMode.rawValue,
            "sessionListLayout": sessionListLayout.rawValue]
        for (key, value) in values { defaults?.set(value, forKey: key) }
        onChange?()
    }
    public func apply(to store: IslandStore) {
        store.systemMetricOptions = systemMetricOptions
        store.sessionListLayout = sessionListLayout
        store.quotaDisplayMode = quotaDisplayMode
        store.warningThreshold = warningThreshold; store.criticalThreshold = criticalThreshold
        store.wingWidth = wingWidth
    }
}
