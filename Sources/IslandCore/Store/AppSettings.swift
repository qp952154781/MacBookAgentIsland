import Foundation

/// Allows settings persistence tests without touching the host's preferences.
@MainActor public protocol AppSettingsDefaults {
    func string(forKey defaultName: String) -> String?
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: AppSettingsDefaults {}

@MainActor @Observable public final class AppSettings {
    public var customSources: [CustomSource] { didSet { persist() } }
    public var providerOrder: [ProviderID] { didSet { persist() } }
    public var declarations: [ProviderDescriptor] {
        ProviderOrder.arrange(ProviderRegistry.ordered + customSources.map(\.descriptor), order: providerOrder)
    }
    public func saveCustomSource(_ source: CustomSource) {
        guard source.isValid else { return }
        if let index = customSources.firstIndex(where: { $0.id == source.id }) { customSources[index] = source }
        else { customSources.append(source) }
    }
    public func deleteCustomSource(_ id: ProviderID) {
        customSources.removeAll { $0.id == id }
        providerOverrides[id] = nil; providerOrder.removeAll { $0 == id }
    }
    public func moveProvider(_ id: ProviderID, by distance: Int) {
        var ids = declarations.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + distance) else { return }
        ids.swapAt(index, index + distance); providerOrder = ids
    }
    public var providerOverrides: [ProviderID: Bool] { didSet { persist() } }
    public func setProviderOverride(_ value: Bool?, for id: ProviderID) { providerOverrides[id] = value }
    public var showGPU: Bool { didSet { persist() } }
    public var showCPU: Bool { didSet { persist() } }
    public var showNetwork: Bool { didSet { persist() } }
    public var showFan: Bool { didSet { persist() } }
    public var showMemory: Bool { didSet { persist() } }
    public var systemMetricOptions: SystemMetricOptions {
        .init(network: showNetwork, fan: showFan, memory: showMemory, cpu: showCPU, gpu: showGPU)
    }
    public var expansionMethod: ExpansionMethod { didSet { persist() } }
    public var collapsedStyle: CollapsedStyle { didSet { persist() } }
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
        let data = defaults?.object(forKey: "customSources") as? Data
        let decoded = data.flatMap { try? JSONDecoder().decode([CustomSource].self, from: $0) } ?? []
        var seen = Set<ProviderID>()
        customSources = decoded.filter { $0.isValid && seen.insert($0.id).inserted }
        providerOrder = (defaults?.object(forKey: "providerOrder") as? [String] ?? []).map(ProviderID.init(rawValue:))
        let saved = defaults?.object(forKey: "providerOverrides") as? [String: Bool] ?? [:]
        providerOverrides = Dictionary(uniqueKeysWithValues: saved.map { (ProviderID(rawValue: $0.key), $0.value) })
        sessionListLayout = defaults?.string(forKey: "sessionListLayout").flatMap(SessionListLayoutMode.init(rawValue:)) ?? .automatic
        expansionMethod = defaults?.string(forKey: "expansionMethod").flatMap(ExpansionMethod.init(rawValue:)) ?? .hover
        collapsedStyle = defaults?.string(forKey: "collapsedStyle").flatMap(CollapsedStyle.init(rawValue:)) ?? .hidden
        quotaDisplayMode = defaults?.string(forKey: "quotaDisplayMode").flatMap(QuotaDisplayMode.init(rawValue:)) ?? .remaining
        func number(_ key: String, _ fallback: Double) -> Double {
            let value = (defaults?.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
            return value.isFinite ? value : fallback
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults?.object(forKey: key) as? Bool ?? fallback }
        showGPU = flag("showGPU", true)
        showCPU = flag("showCPU", true)
        showNetwork = flag("showNetwork", true)
        showFan = flag("showFan", true)
        showMemory = flag("showMemory", true)
        let interval = number("refreshInterval", 120)
        refreshInterval = [30, 60, 120, 300].contains(interval) ? Int(interval) : 120
        let warning = min(98, max(1, number("warningThreshold", 70)))
        warningThreshold = warning
        criticalThreshold = min(100, max(warning + 1, number("criticalThreshold", 90)))
        wingWidth = min(100, max(IslandLayout.minimumWingWidth, number("wingWidth", 76)))
        useMainScreen = flag("useMainScreen", false)
        showInFullscreen = flag("showInFullscreen", false)
        launchAtLogin = flag("launchAtLogin", false)
        let active = number("activeMinutes", 30)
        activeMinutes = [15, 30, 60].contains(active) ? Int(active) : 30
    }
    private func persist() {
        let values: [String: Any] = ["showGPU": showGPU, "showCPU": showCPU, "showNetwork": showNetwork, "showFan": showFan, "showMemory": showMemory, "refreshInterval": refreshInterval, "warningThreshold": warningThreshold,
            "criticalThreshold": criticalThreshold, "wingWidth": wingWidth, "useMainScreen": useMainScreen,
            "showInFullscreen": showInFullscreen, "launchAtLogin": launchAtLogin, "activeMinutes": activeMinutes,
            "expansionMethod": expansionMethod.rawValue, "quotaDisplayMode": quotaDisplayMode.rawValue,
            "sessionListLayout": sessionListLayout.rawValue, "collapsedStyle": collapsedStyle.rawValue]
        defaults?.set(try? JSONEncoder().encode(customSources), forKey: "customSources")
        defaults?.set(providerOrder.map(\.rawValue), forKey: "providerOrder")
        defaults?.set(Dictionary(uniqueKeysWithValues: providerOverrides.map { ($0.key.rawValue, $0.value) }), forKey: "providerOverrides")
        for (key, value) in values { defaults?.set(value, forKey: key) }
        onChange?()
    }
    public func apply(to store: IslandStore) {
        store.customSources = customSources
        store.providerOrder = providerOrder
        store.providerOverrides = providerOverrides
        store.systemMetricOptions = systemMetricOptions
        store.sessionListLayout = sessionListLayout
        store.quotaDisplayMode = quotaDisplayMode
        store.collapsedStyle = collapsedStyle
        store.warningThreshold = warningThreshold; store.criticalThreshold = criticalThreshold
        store.wingWidth = wingWidth
    }
}
