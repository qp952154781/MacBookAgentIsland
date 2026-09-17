import Foundation
import IslandCore

@MainActor @Observable final class IslandViewModel {
    let store: IslandStore
    let forcedState: IslandMode?
    private(set) var interaction = IslandInteraction()
    var animationsVisible = true { didSet { updateSystemMetrics() } }
    @ObservationIgnored private var systemMonitor: SystemMetricsMonitor?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    var mode: IslandMode {
        if let forcedState { return forcedState }
        if interaction.expanded { return .expanded }
        return store.anyWorking ? .active : .collapsed
    }

    init(store: IslandStore, forcedState: IslandMode? = nil) {
        self.store = store
        self.forcedState = forcedState
        store.onProviderChange = { [weak self] in self?.updateSystemMetrics() }
    }

    func setExpansionMethod(_ method: ExpansionMethod) {
        guard interaction.method != method else { return }
        hoverTask?.cancel()
        interaction.setMethod(method)
        updateSystemMetrics()
    }

    func setHovered(_ inside: Bool) {
        guard forcedState == nil, inside != interaction.hovered else { return }
        interaction.setHovered(inside)
        hoverTask?.cancel()
        guard interaction.method == .hover else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(inside ? 120 : 350)) } catch { return }
            self?.interaction.settleHover()
            self?.updateSystemMetrics()
        }
    }

    func togglePinned() {
        guard forcedState == nil else { return }
        hoverTask?.cancel()
        interaction.click()
        updateSystemMetrics()
    }

    func clickedOutside() {
        guard forcedState == nil else { return }
        hoverTask?.cancel()
        interaction.clickOutside()
        updateSystemMetrics()
    }

    func enableSystemMetrics(provider: any SystemMetricsProviding = LiveSystemMetricsProvider(),
                             scheduler: any SystemSamplingScheduler = LiveSystemSamplingScheduler()) {
        systemMonitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) { [weak store] in store?.systemMetrics = $0 }
        updateSystemMetrics()
    }

    func updateSystemMetrics(reset: Bool = false) {
        let collapsed = store.collapsedMetricOptions
        let needsSampling = mode == .expanded || collapsed.enabled
        let options = mode == .expanded || !collapsed.enabled ? store.expandedMetricOptions : collapsed
        systemMonitor?.update(expanded: animationsVisible && needsSampling, options: options, reset: reset)
    }

    func stop() {
        systemMonitor?.stop()
        systemMonitor = nil
        hoverTask?.cancel()
        hoverTask = nil
        animationsVisible = false
    }
}
