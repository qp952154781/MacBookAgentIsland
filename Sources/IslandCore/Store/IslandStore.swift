import Foundation

@MainActor @Observable public final class IslandStore {
    public var systemMetrics = SystemMetrics()
    public var systemMetricOptions = SystemMetricOptions()
    public var claudeConnection: ClaudeConnectionStatus?
    public var quotas: [AgentKind: QuotaSnapshot] = [:]
    public private(set) var quotaDiagnostics: [AgentKind: String] = [:]
    public var health: [AgentKind: ProviderHealth] = [:]
    public private(set) var firstQuotaMs: Double?
    public private(set) var firstSessionMs: Double?
    public var sessionsLoaded = false
    public private(set) var sessionWarnings: [AgentKind: String] = [:]
    @ObservationIgnored private let processStarted: ContinuousClock.Instant
    public var sessions: [AgentSession] = [] {
        didSet {
            if sessions != oldValue {
                displaySessions = SessionDisplayOrder.sorted(sessions)
                displaySessionColumns = SessionDisplayOrder.columns(sessions)
            }
        }
    }
    public private(set) var displaySessions: [AgentSession] = []
    public private(set) var displaySessionColumns: [[AgentSession]] = [[], []]
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
    @ObservationIgnored private var awaitingQuota: Set<AgentKind> = []
    @ObservationIgnored private var lastTokenRefresh: Date?
    @ObservationIgnored private var visible = true

    public init(quotaService: (any QuotaServicing)? = nil, sessionService: (any SessionServicing)? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                processStarted: ContinuousClock.Instant = .now) {
        self.processStarted = processStarted
        self.quotaService = quotaService; self.sessionService = sessionService; self.clock = clock
    }

    deinit {
        tasks.forEach { $0.cancel() }
        let quota = quotaService, sessions = sessionService
        Task {
            async let quotaStop: Void? = quota?.stop()
            async let sessionStop: Void? = sessions?.stop()
            _ = await (quotaStop, sessionStop)
        }
    }

    public func start() async {
        guard !Task.isCancelled, !isRunning, let quotaService, let sessionService else { return }
        isRunning = true
        epoch = UUID()
        let token = epoch
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
        async let quotaStart: Void = quotaService.start()
        async let sessionStart: Void = sessionService.start()
        _ = await (quotaStart, sessionStart)
    }

    public func stop() async {
        isRunning = false; epoch = UUID()
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        awaitingQuota.removeAll(); isRefreshing = false
        async let quotaStop: Void? = quotaService?.stop()
        async let sessionStop: Void? = sessionService?.stop()
        _ = await (quotaStop, sessionStop)
    }

    public func refreshNow(agent: AgentKind? = nil) async {
        guard isRunning else { return }
        awaitingQuota.formUnion(agent.map { [$0] } ?? AgentKind.allCases)
        isRefreshing = true
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

    public func retryClaudeConnection() async { await quotaService?.retryClaudeConnection() }

    private func receive(_ update: QuotaUpdate) {
        if let status = update.claudeConnection { claudeConnection = status }
        if let snapshot = update.snapshot {
            if firstQuotaMs == nil { firstQuotaMs = elapsedMilliseconds() }
            quotas[update.agent] = snapshot
        }
        quotaDiagnostics[update.agent] = update.diagnostic
        health[update.agent] = update.health
        lastRefresh = clock()
        awaitingQuota.remove(update.agent)
        isRefreshing = !awaitingQuota.isEmpty
    }

    private func receive(_ update: SessionUpdate) async {
        if firstSessionMs == nil { firstSessionMs = elapsedMilliseconds() }
        sessionsLoaded = true
        sessionWarnings = update.warnings
        if sessions != update.sessions { sessions = update.sessions }
        expandedSessionIDs.formIntersection(Set(sessions.map(\.id)))
        let now = clock()
        if visible, update.codexTokenCountChanged, lastTokenRefresh.map({ (now.timeIntervalSince($0) >= 60 || now < $0) }) ?? true {
            lastTokenRefresh = now
            await quotaService?.refreshNow(agent: .codex)
        }
    }

    private func elapsedMilliseconds() -> Double {
        let value = processStarted.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }

    public func workingSessions(for agent: AgentKind) -> [AgentSession] {
        sessions.filter { $0.agent == agent && $0.phase.isWorking }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
    public func headline(for agent: AgentKind) -> QuotaWindow? {
        switch health[agent] {
        case .needsSetup, .failed, .disabled: nil
        default: quotas[agent].flatMap { quotaDisplayMode.headline($0) }
        }
    }
    public var layoutConfig: IslandLayoutConfig {
        var config = IslandLayoutConfig(); config.wingWidth = wingWidth; return config
    }
    public func sessionLayout(notch: NotchMetrics) -> SessionListLayout {
        SessionListLayout(mode: sessionListLayout, activeCount: sessions.filter { $0.phase != .ended }.count,
                          notch: notch, singleColumnWidth: layoutConfig.expandedWidth)
    }
    public func layoutConfig(notch: NotchMetrics) -> IslandLayoutConfig {
        var config = layoutConfig
        config.expandedWidth = sessionLayout(notch: notch).width
        return config
    }
    public var anyWorking: Bool { sessions.contains { $0.phase.isWorking } }

    public func sessionColumns(count: Int) -> [[AgentSession]] {
        count == 2 ? displaySessionColumns : [displaySessions]
    }
}
