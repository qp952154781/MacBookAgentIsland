import Foundation

@MainActor @Observable public final class IslandStore {
    public var systemMetrics = SystemMetrics()
    public var systemMetricOptions = SystemMetricOptions()
    public var claudeConnection: ClaudeConnectionStatus?
    public var quotas: [ProviderID: QuotaSnapshot] = [:] { didSet { onProviderChange?() } }
    public private(set) var quotaWarnings: [ProviderID: [String]] = [:]
    public private(set) var quotaDiagnostics: [ProviderID: String] = [:]
    public var health: [ProviderID: ProviderHealth] = [:] { didSet { onProviderChange?() } }
    public private(set) var firstQuotaMs: Double?
    public private(set) var firstSessionMs: Double?
    public var sessionsLoaded = false
    public private(set) var sessionWarnings: [ProviderID: String] = [:]
    @ObservationIgnored private let processStarted: ContinuousClock.Instant
    public var providerDeclarations = ProviderRegistry.ordered { didSet { providersChanged() } }
    public var providerDetection: ProviderDetection { didSet { providersChanged() } }
    public var providerOverrides: [ProviderID: Bool] = [:] { didSet { if oldValue != providerOverrides { providersChanged() } } }
    public var latestClaudeModel: String? { didSet { if oldValue != latestClaudeModel { providersChanged() } } }
    public var customSources: [CustomSource] = [] { didSet { if oldValue != customSources { providersChanged() } } }
    public var providerOrder: [ProviderID] = [] { didSet { if oldValue != providerOrder { providersChanged() } } }
    public var declarations: [ProviderDescriptor] {
        ProviderOrder.arrange(providerDeclarations + customSources.map(\.descriptor), order: providerOrder)
    }
    public func descriptor(for id: ProviderID) -> ProviderDescriptor {
        declarations.first { $0.id == id } ?? ProviderRegistry.descriptor(for: id)
    }
    public var providerStates: [ProviderState] {
        var detection = providerDetection
        for source in customSources { detection.installed[source.id] = true }
        return ProviderAvailability.resolve(declarations: declarations, detection: detection,
                                     overrides: providerOverrides, latestClaudeModel: latestClaudeModel)
    }
    public var visibleProviderIDs: [ProviderID] { providerStates.filter(\.hasContent).map(\.id) }
    public var quotaProviderIDs: [ProviderID] { providerStates.filter(\.quotaAvailable).map(\.id) }
    public var sessionProviderIDs: [ProviderID] { providerStates.filter(\.sessionsAvailable).map(\.id) }
    private var quotaServiceIDs: [ProviderID] { providerStates.filter { $0.quotaAvailable && $0.detected }.map(\.id) }
    private var sessionServiceIDs: [ProviderID] { providerStates.filter { $0.sessionsAvailable && $0.detected }.map(\.id) }
    public var sessions: [AgentSession] = [] {
        didSet { if sessions != oldValue { updateDisplaySessions() } }
    }
    public private(set) var displaySessions: [AgentSession] = []
    public private(set) var displaySessionColumns: [[AgentSession]] = [[], []]
    @ObservationIgnored public var onProviderChange: (() -> Void)?
    @ObservationIgnored private let providerClock: any QuotaClock
    @ObservationIgnored private let providerDetector: (any ProviderDetecting)?
    @ObservationIgnored private var providerTask: Task<Void, Never>?
    @ObservationIgnored private var detectionGeneration = 0
    @ObservationIgnored private var starting = false

    private func updateDisplaySessions() {
        let visible = sessions.filter { sessionServiceIDs.contains($0.agent) }
        displaySessions = SessionDisplayOrder.sorted(visible)
        displaySessionColumns = SessionDisplayOrder.columns(visible, providers: sessionProviderIDs)
    }
    public func setMockDiagnostic(_ message: String, for id: ProviderID) { quotaDiagnostics[id] = message }
    private func providersChanged() {
        let known = Set(declarations.map(\.id))
        for id in quotas.keys where !known.contains(id) { quotas[id] = nil; health[id] = nil; quotaDiagnostics[id] = nil; quotaWarnings[id] = nil }
        for state in providerStates {
            if !state.detected || state.thirdPartyBackend {
                quotas[state.id] = nil
                health[state.id] = state.enabled && !state.thirdPartyBackend
                    ? .needsSetup(message: "未检测到 " + state.name) : nil
                if state.id == .claude { claudeConnection = nil }
            }
        }
        updateDisplaySessions()
        awaitingQuota.formIntersection(Set(quotaServiceIDs)); isRefreshing = !awaitingQuota.isEmpty
        onProviderChange?()
        guard isRunning, !starting else { return }
        let previous = providerTask
        providerTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.applyProviderServices()
        }
    }
    private func applyProviderServices() async {
        // Cancel removed commands before any potentially slow session work.
        await quotaService?.setCustomSources(customSources)
        await quotaService?.setEnabledProviders(quotaServiceIDs)
        guard !Task.isCancelled else { return }
        await sessionService?.setEnabledProviders(sessionServiceIDs)
        if let update = await sessionService?.latestUpdate() { await receive(update) }
    }
    public func detectProviders() async {
        guard let providerDetector else { return }
        detectionGeneration += 1
        let token = detectionGeneration
        let detected = await providerDetector.detect()
        guard !Task.isCancelled, token == detectionGeneration else { return }
        if detected != providerDetection { providerDetection = detected }
        await providerTask?.value
    }
    public var sessionListLayout: SessionListLayoutMode = .automatic
    public var lastRefresh: Date?
    public private(set) var isRunning = false
    public private(set) var isRefreshing = false
    public var warningThreshold: Double = 70
    public var criticalThreshold: Double = 90
    public var quotaDisplayMode: QuotaDisplayMode = .remaining
    public var wingWidth: Double = 76
    public var expandedSessionIDs: Set<String> = []
    @ObservationIgnored private let quotaService: (any QuotaServicing)?
    @ObservationIgnored private let sessionService: (any SessionServicing)?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var awaitingQuota: Set<ProviderID> = []
    @ObservationIgnored private var lastTokenRefresh: Date?
    @ObservationIgnored private var visible = true

    public init(providerDetector: (any ProviderDetecting)? = nil, providerClock: any QuotaClock = SystemQuotaClock(), quotaService: (any QuotaServicing)? = nil, sessionService: (any SessionServicing)? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                processStarted: ContinuousClock.Instant = .now) {
        self.providerClock = providerClock
        self.providerDetector = providerDetector
        providerDetection = ProviderDetection(installed: providerDetector == nil ? [.claude: true, .codex: true] : [:])
        self.processStarted = processStarted
        self.quotaService = quotaService; self.sessionService = sessionService; self.clock = clock
    }

    deinit {
        tasks.forEach { $0.cancel() }; providerTask?.cancel()
        let quota = quotaService, sessions = sessionService
        Task {
            async let quotaStop: Void? = quota?.stop()
            async let sessionStop: Void? = sessions?.stop()
            _ = await (quotaStop, sessionStop)
        }
    }

    public func start() async {
        guard !Task.isCancelled, !isRunning, let quotaService, let sessionService else { return }
        isRunning = true; starting = true
        defer { starting = false }
        epoch = UUID()
        let token = epoch
        await detectProviders()
        guard !Task.isCancelled, isRunning, token == epoch else { return }
        await applyProviderServices()
        let quotaStream = await quotaService.updates()
        let sessionStream = await sessionService.updates()
        guard !Task.isCancelled, isRunning, token == epoch else { return }
        tasks.append(Task { [weak self] in
            for await update in quotaStream {
                guard !Task.isCancelled, let self, self.epoch == token else { break }
                self.receive(update)
            }
        })
        tasks.append(Task { [weak self] in
            for await update in sessionStream {
                guard !Task.isCancelled, let self, self.epoch == token else { break }
                await self.receive(update)
            }
        })
        // Resolve the already parsed session model before starting any quota worker.
        await sessionService.start()
        if let update = await sessionService.latestUpdate() { await receive(update) }
        guard !Task.isCancelled, isRunning, token == epoch else { return }
        await applyProviderServices()
        await quotaService.start()
        if providerDetector != nil {
            tasks.append(Task { [weak self, providerClock] in
                while !Task.isCancelled {
                    do { try await providerClock.sleep(for: 300) } catch { break }
                    await self?.detectProviders()
                }
            })
        }
    }

    public func stop() async {
        isRunning = false; epoch = UUID(); detectionGeneration += 1
        providerTask?.cancel(); providerTask = nil
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        awaitingQuota.removeAll(); isRefreshing = false
        async let quotaStop: Void? = quotaService?.stop()
        async let sessionStop: Void? = sessionService?.stop()
        _ = await (quotaStop, sessionStop)
    }

    public func refreshNow(agent: ProviderID? = nil) async {
        await providerTask?.value
        guard isRunning else { return }
        awaitingQuota.formUnion((agent.map { [$0] } ?? quotaServiceIDs).filter { quotaServiceIDs.contains($0) })
        isRefreshing = !awaitingQuota.isEmpty
        async let quotaRefresh: Void? = quotaService?.refreshNow(agent: agent)
        async let sessionRefresh: Void? = sessionService?.refreshNow()
        _ = await (quotaRefresh, sessionRefresh)
    }

    public func configure(interval: TimeInterval, activeWindow: TimeInterval) async {
        async let quota: Void? = quotaService?.setInterval(interval)
        async let session: Void? = sessionService?.setActiveWindow(activeWindow)
        _ = await (quota, session)
    }

    public func setVisible(_ visible: Bool) async {
        self.visible = visible
        if !visible { awaitingQuota.removeAll(); isRefreshing = false }
        async let sessions: Void? = sessionService?.setVisible(visible)
        async let quota: Void? = quotaService?.setSuspended(!visible)
        _ = await (sessions, quota)
    }

    public func retryClaudeConnection() async {
        guard quotaServiceIDs.contains(.claude) else { return }
        await quotaService?.retryClaudeConnection()
    }

    private func receive(_ update: QuotaUpdate) {
        guard quotaServiceIDs.contains(update.agent) else { return }
        if let status = update.claudeConnection { claudeConnection = status }
        if let snapshot = update.snapshot {
            if firstQuotaMs == nil { firstQuotaMs = elapsedMilliseconds() }
            quotas[update.agent] = snapshot
        }
        quotaDiagnostics[update.agent] = update.diagnostic
        if let warnings = update.warnings { quotaWarnings[update.agent] = warnings }
        health[update.agent] = update.health
        lastRefresh = clock()
        awaitingQuota.remove(update.agent)
        isRefreshing = !awaitingQuota.isEmpty
    }

    private func receive(_ update: SessionUpdate) async {
        if firstSessionMs == nil { firstSessionMs = elapsedMilliseconds() }
        sessionsLoaded = true
        if let model = update.latestClaudeModel { latestClaudeModel = model }
        sessionWarnings = update.warnings
        if sessions != update.sessions { sessions = update.sessions }
        expandedSessionIDs.formIntersection(Set(sessions.map(\.id)))
        let now = clock()
        if visible, !starting, quotaServiceIDs.contains(.codex), update.codexTokenCountChanged, lastTokenRefresh.map({ (now.timeIntervalSince($0) >= 60 || now < $0) }) ?? true {
            lastTokenRefresh = now
            await quotaService?.refreshNow(agent: .codex)
        }
    }

    private func elapsedMilliseconds() -> Double {
        let value = processStarted.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    public func workingSessions(for agent: ProviderID) -> [AgentSession] {
        displaySessions.filter { $0.agent == agent && $0.phase.isWorking }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
    public func headline(for agent: ProviderID) -> QuotaWindow? {
        switch health[agent] {
        case .needsSetup, .failed, .disabled: nil
        default: quotas[agent].flatMap { quotaDisplayMode.headline($0) }
        }
    }
    public var layoutConfig: IslandLayoutConfig {
        var config = IslandLayoutConfig(); config.wingWidth = wingWidth; return config
    }
    public func sessionLayout(notch: NotchMetrics) -> SessionListLayout {
        SessionListLayout(mode: sessionProviderIDs.count == 2 ? sessionListLayout : .singleColumn, activeCount: displaySessions.filter { $0.phase != .ended }.count,
                          notch: notch, singleColumnWidth: layoutConfig.expandedWidth)
    }
    public func layoutConfig(notch: NotchMetrics) -> IslandLayoutConfig {
        var config = layoutConfig
        config.expandedWidth = sessionLayout(notch: notch).width
        return config
    }
    public var anyWorking: Bool { displaySessions.contains { $0.phase.isWorking } }

    public func sessionColumns(count: Int) -> [[AgentSession]] {
        guard !sessionProviderIDs.isEmpty else { return [] }
        return count == 2 ? displaySessionColumns : [displaySessions]
    }
}
