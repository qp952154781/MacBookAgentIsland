import Foundation

public struct QuotaUpdate: Sendable, Equatable, Codable {
    public let agent: AgentKind
    public let snapshot: QuotaSnapshot?
    public let health: ProviderHealth
    public let diagnostic: String?
    public let claudeConnection: ClaudeConnectionStatus?
    public init(agent: AgentKind, snapshot: QuotaSnapshot?, health: ProviderHealth, diagnostic: String? = nil, claudeConnection: ClaudeConnectionStatus? = nil) {
        self.agent = agent; self.snapshot = snapshot; self.health = health; self.diagnostic = diagnostic; self.claudeConnection = claudeConnection
    }
}

public protocol QuotaClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemQuotaClock: QuotaClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

public actor QuotaService: QuotaServicing {
    private let providers: [AgentKind: any QuotaProviding]
    private var intervals: [AgentKind: TimeInterval]
    private let diagnostics: ClaudeDiagnostics
    private let clock: any QuotaClock
    private let jitter: @Sendable () -> Double
    private var workers: [AgentKind: Task<Void, Never>] = [:]
    private var versions: [AgentKind: UUID] = [:]
    private var snapshots: [AgentKind: QuotaSnapshot] = [:]
    private var latest: [AgentKind: QuotaUpdate] = [:]
    private var claudeConnection: ClaudeConnectionStatus?
    private var failures: [AgentKind: Int] = [:]
    private var subscribers: [UUID: AsyncStream<QuotaUpdate>.Continuation] = [:]
    public private(set) var refreshCounts: [AgentKind: Int] = [:]
    private var running = false
    private var suspended = false
    private var lifecycle = UUID()

    public init(providers: [any QuotaProviding] = [ClaudeQuotaProvider(), CodexQuotaProvider()],
                intervals: [AgentKind: TimeInterval] = [.claude: 120, .codex: 120],
                clock: any QuotaClock = SystemQuotaClock(), diagnostics: ClaudeDiagnostics = .disabled, jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }) {
        var byAgent: [AgentKind: any QuotaProviding] = [:]
        for provider in providers { byAgent[provider.agent] = provider }
        self.diagnostics = diagnostics; self.providers = byAgent; self.intervals = intervals; self.clock = clock; self.jitter = jitter
    }

    public func setInterval(_ seconds: TimeInterval) async {
        let value = seconds.isFinite ? max(30, seconds) : 60
        guard AgentKind.allCases.contains(where: { intervals[$0] != value }) else { return }
        for agent in AgentKind.allCases { intervals[agent] = value }
        if running { await refreshNow() }
    }

    public func updates() -> AsyncStream<QuotaUpdate> {
        let id = UUID()
        let pair = AsyncStream<QuotaUpdate>.makeStream(bufferingPolicy: .bufferingNewest(max(1, providers.count)))
        subscribers[id] = pair.continuation
        for agent in AgentKind.allCases { if let update = latest[agent] { pair.continuation.yield(update) } }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return pair.stream
    }

    public func start() {
        guard !running else { return }
        running = true; lifecycle = UUID()
        guard !suspended else { return }
        for agent in providers.keys where workers[agent] == nil { launch(agent, repeating: true) }
    }

    /// Preserve subscribers while hidden; wake resumes the existing store connection.
    public func setSuspended(_ value: Bool) async {
        guard suspended != value else { return }
        suspended = value; lifecycle = UUID()
        if value {
            let tasks = Array(workers.values)
            workers.removeAll(); versions.removeAll()
            tasks.forEach { $0.cancel() }
            for task in tasks { await task.value }
        } else if running {
            await (providers[.claude] as? any ClaudeConnectionProviding)?.retryConnection()
            for agent in providers.keys where workers[agent] == nil { launch(agent, repeating: true) }
        }
    }

    public func stop() async {
        running = false; lifecycle = UUID()
        let tasks = Array(workers.values)
        workers.removeAll(); versions.removeAll()
        tasks.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }; subscribers.removeAll()
        for task in tasks { await task.value }
    }

    /// Interrupts the selected sleep/query and waits for cancellation before starting its replacement.
    /// While stopped this performs one query; it does not start a scheduling loop.
    public func refreshNow(agent: AgentKind? = nil) async {
        guard !suspended else { return }
        let selected = agent.map { [$0] } ?? AgentKind.allCases
        let epoch = lifecycle
        var replaced: [(AgentKind, UUID, Task<Void, Never>?)] = []
        for key in selected where providers[key] != nil {
            let token = UUID(), task = workers[key]
            versions[key] = token
            task?.cancel()
            replaced.append((key, token, task))
        }
        for (_, _, task) in replaced { await task?.value }
        guard epoch == lifecycle else { return }
        for (key, token, _) in replaced where versions[key] == token { launch(key, repeating: running) }
    }

    public func retryClaudeConnection() async {
        await (providers[.claude] as? any ClaudeConnectionProviding)?.retryConnection()
        await refreshNow(agent: .claude)
    }
    private func connectionChanged(_ status: ClaudeConnectionStatus, version: UUID) async {
        guard versions[.claude] == version else { return }
        claudeConnection = status
        let snapshot = snapshots[.claude]
        let health = (status.isRefreshing || status.isRecovering) ? snapshot.map { ProviderHealth.stale(lastSuccess: $0.fetchedAt) }
            ?? .failed(message: ClaudeOAuthUsageClient.recoveringMessage) : latest[.claude]?.health ?? .ok
        let update = QuotaUpdate(agent: .claude, snapshot: snapshot, health: health, claudeConnection: status)
        await recordHealth(update)
        guard versions[.claude] == version, !Task.isCancelled else { return }
        latest[.claude] = update
        subscribers.values.forEach { $0.yield(update) }
    }

    private func launch(_ agent: AgentKind, repeating: Bool) {
        let version = UUID()
        versions[agent] = version
        workers[agent] = Task { [weak self] in await self?.run(agent, version: version, repeating: repeating) }
    }

    private func run(_ agent: AgentKind, version: UUID, repeating: Bool) async {
        guard let provider = providers[agent] else { return }
        async let bootstrap: Void = loadInitialQuota(provider, agent: agent, version: version)
        while !Task.isCancelled, versions[agent] == version {
            let update: QuotaUpdate
            var error: QuotaError?
            do {
                refreshCounts[agent, default: 0] += 1
                let snapshot: QuotaSnapshot
                if let claude = provider as? any ClaudeConnectionProviding {
                    snapshot = try await claude.fetchQuota { [weak self] status in
                        await self?.connectionChanged(status, version: version)
                    }
                } else { snapshot = try await provider.fetchQuota() }
                guard !Task.isCancelled, versions[agent] == version else { return }
                snapshots[agent] = snapshot; failures[agent] = 0
                update = QuotaUpdate(agent: agent, snapshot: snapshot, health: .ok, claudeConnection: agent == .claude ? claudeConnection : nil)
            } catch let caught {
                guard !(caught is CancellationError), !Task.isCancelled, versions[agent] == version else { return }
                error = (caught as? QuotaError) ?? .transient("额度查询失败")
                failures[agent] = min(20, (failures[agent] ?? 0) + 1)
                let failure = error ?? .transient("额度查询失败")
                let health: ProviderHealth
                switch failure {
                case let .notConfigured(message), let .unauthorized(message): health = .needsSetup(message: message)
                default:
                    if let snapshot = snapshots[agent] { health = .stale(lastSuccess: snapshot.fetchedAt) }
                    else { health = .failed(message: failure.message) }
                }
                update = QuotaUpdate(agent: agent, snapshot: snapshots[agent], health: health, diagnostic: failure.message, claudeConnection: agent == .claude ? claudeConnection : nil)
            }
            await recordHealth(update)
            guard versions[agent] == version, !Task.isCancelled else { return }
            latest[agent] = update
            subscribers.values.forEach { $0.yield(update) }
            guard repeating else { break }
            do { try await clock.sleep(for: delay(agent: agent, error: error)) }
            catch { break }
        }
        await bootstrap
        if versions[agent] == version { workers[agent] = nil; versions[agent] = nil }
    }

    private func loadInitialQuota(_ provider: any QuotaProviding, agent: AgentKind, version: UUID) async {
        guard snapshots[agent] == nil, let initial = provider as? any InitialQuotaProviding,
              let snapshot = await initial.initialQuota(), !Task.isCancelled,
              versions[agent] == version, snapshots[agent] == nil else { return }
        snapshots[agent] = snapshot
        let update = QuotaUpdate(agent: agent, snapshot: snapshot, health: .stale(lastSuccess: snapshot.fetchedAt))
        latest[agent] = update
        subscribers.values.forEach { $0.yield(update) }
    }

    private func delay(agent: AgentKind, error: QuotaError?) -> TimeInterval {
        if case .notConfigured = error { return 300 }
        let configured = intervals[agent] ?? 120
        let base = configured.isFinite ? max(1, configured) : 60
        if agent == .claude, let retry = claudeConnection?.nextRetryAt, retry > clock.now() {
            // Keep the ordinary attribute poll cadence, but never sleep past a recovery deadline.
            return max(1, min(base, retry.timeIntervalSince(clock.now())))
        }
        let multiplier = error == nil ? 1 : pow(2, Double(failures[agent] ?? 1))
        let random = jitter()
        let factor = 1 + 0.1 * (random.isFinite ? max(-1, min(1, random)) : 0)
        if error == nil { return base * factor }
        return min(600, min(600, base * multiplier) * factor)
    }

    private func recordHealth(_ update: QuotaUpdate) async {
        guard update.agent == .claude else { return }
        let previous = latest[.claude].map { ClaudeDiagnostics.category($0.health) }
        let category = ClaudeDiagnostics.category(update.health)
        guard previous != category else { return }
        await diagnostics.record(.healthChange, at: clock.now(), category: category, previous: previous)
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
