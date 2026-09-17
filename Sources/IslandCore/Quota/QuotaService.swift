import Foundation

public struct QuotaUpdate: Sendable, Equatable, Codable {
    public let agent: ProviderID
    public let snapshot: QuotaSnapshot?
    public let health: ProviderHealth
    public let diagnostic: String?
    public let warnings: [String]?
    public let claudeConnection: ClaudeConnectionStatus?
    public init(agent: ProviderID, snapshot: QuotaSnapshot?, health: ProviderHealth, diagnostic: String? = nil, warnings: [String]? = nil, claudeConnection: ClaudeConnectionStatus? = nil) {
        self.warnings = warnings
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
    private var providers: [ProviderID: any QuotaProviding]
    private var customSources: [CustomSource] = []
    private let customRunner: CustomCommandRunner
    private let allowsCustomCommands: Bool
    private var enabledIDs: [ProviderID]
    private var intervals: [ProviderID: TimeInterval]
    private let diagnostics: ClaudeDiagnostics
    private let clock: any QuotaClock
    private let jitter: @Sendable () -> Double
    private var workers: [ProviderID: Task<Void, Never>] = [:]
    private var versions: [ProviderID: UUID] = [:]
    private var snapshots: [ProviderID: QuotaSnapshot] = [:]
    private var latest: [ProviderID: QuotaUpdate] = [:]
    private var claudeConnection: ClaudeConnectionStatus?
    private var failures: [ProviderID: Int] = [:]
    private var subscribers: [UUID: AsyncStream<QuotaUpdate>.Continuation] = [:]
    public private(set) var refreshCounts: [ProviderID: Int] = [:]
    private var running = false
    private var suspended = false
    private var lifecycle = UUID()
    private var providerVersion = UUID()

    public init(providers: [any QuotaProviding] = [ClaudeQuotaProvider(), CodexQuotaProvider()],
                intervals: [ProviderID: TimeInterval] = [.claude: 120, .codex: 120],
                clock: any QuotaClock = SystemQuotaClock(), customRunner: CustomCommandRunner = .shared, allowsCustomCommands: Bool = true, diagnostics: ClaudeDiagnostics = .disabled, jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }) {
        self.customRunner = customRunner; self.allowsCustomCommands = allowsCustomCommands
        var byAgent: [ProviderID: any QuotaProviding] = [:]
        for provider in providers { byAgent[provider.agent] = provider }
        self.enabledIDs = providers.map(\.agent)
        self.diagnostics = diagnostics; self.providers = byAgent; self.intervals = intervals; self.clock = clock; self.jitter = jitter
    }

    public func setCustomSources(_ sources: [CustomSource]) async {
        guard allowsCustomCommands, customSources != sources else { return }
        let changed = customSources.filter { old in !sources.contains(old) }.map(\.id)
        customSources = sources
        let tasks = changed.compactMap { workers.removeValue(forKey: $0) }
        for id in changed { versions[id] = nil; providers[id] = nil; latest[id] = nil; snapshots[id] = nil }
        tasks.forEach { $0.cancel() }
        for id in changed { await customRunner.cancel(source: id); await customRunner.forget(id) }
        for task in tasks { await task.value }
        guard customSources == sources else { return }
        for source in sources {
            providers[source.id] = CustomQuotaProvider(source: source, runner: customRunner)
            intervals[source.id] = source.interval
        }
        // setEnabledProviders follows this reconciliation and launches added/replaced workers.
        enabledIDs.removeAll { changed.contains($0) || providers[$0] == nil }
    }

    public func setEnabledProviders(_ ids: [ProviderID]) async {
        let next = ids.filter { providers[$0] != nil }
        guard next != enabledIDs else { return }
        let removed = enabledIDs.filter { !next.contains($0) }
        enabledIDs = next
        providerVersion = UUID()
        let token = providerVersion
        let cancelled = removed.compactMap { workers.removeValue(forKey: $0) }
        for id in removed { versions[id] = nil; latest[id] = nil; snapshots[id] = nil; failures[id] = nil }
        cancelled.forEach { $0.cancel() }
        for id in removed where customSources.contains(where: { $0.id == id }) { await customRunner.cancel(source: id) }
        for task in cancelled { await task.value }
        guard token == providerVersion, running, !suspended, !Task.isCancelled else { return }
        for id in enabledIDs where workers[id] == nil { launch(id, repeating: true) }
    }

    public func setInterval(_ seconds: TimeInterval) async {
        let value = seconds.isFinite ? max(30, seconds) : 60
        guard ProviderRegistry.orderedIDs.contains(where: { intervals[$0] != value }) else { return }
        for agent in ProviderRegistry.orderedIDs { intervals[agent] = value }
        if running { for id in ProviderRegistry.orderedIDs { await refreshNow(agent: id) } }
    }

    public func updates() -> AsyncStream<QuotaUpdate> {
        let id = UUID()
        let pair = AsyncStream<QuotaUpdate>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = pair.continuation
        for agent in enabledIDs { if let update = latest[agent] { pair.continuation.yield(update) } }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return pair.stream
    }

    public func start() {
        guard !running else { return }
        running = true; lifecycle = UUID()
        guard !suspended else { return }
        for agent in enabledIDs where workers[agent] == nil { launch(agent, repeating: true) }
    }

    /// Preserve subscribers while hidden; wake resumes the existing store connection.
    public func setSuspended(_ value: Bool) async {
        guard suspended != value else { return }
        suspended = value; lifecycle = UUID()
        if allowsCustomCommands { await customRunner.setSuspended(value) }
        if value {
            let tasks = Array(workers.values)
            workers.removeAll(); versions.removeAll()
            tasks.forEach { $0.cancel() }
            for task in tasks { await task.value }
        } else if running {
            if enabledIDs.contains(.claude) { await (providers[.claude] as? any ClaudeConnectionProviding)?.retryConnection() }
            for agent in enabledIDs where workers[agent] == nil { launch(agent, repeating: true) }
        }
    }

    public func stop() async {
        running = false; lifecycle = UUID()
        let tasks = Array(workers.values)
        workers.removeAll(); versions.removeAll()
        tasks.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }; subscribers.removeAll()
        if allowsCustomCommands { await customRunner.cancelAll() }
        for task in tasks { await task.value }
    }

    /// Interrupts the selected sleep/query and waits for cancellation before starting its replacement.
    /// While stopped this performs one query; it does not start a scheduling loop.
    public func refreshNow(agent: ProviderID? = nil) async {
        guard !suspended else { return }
        let selected = agent.map { [$0] } ?? enabledIDs
        let epoch = lifecycle
        var replaced: [(ProviderID, UUID, Task<Void, Never>?)] = []
        for key in selected where enabledIDs.contains(key) && providers[key] != nil {
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
        guard enabledIDs.contains(.claude) else { return }
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

    private func launch(_ agent: ProviderID, repeating: Bool) {
        let version = UUID()
        versions[agent] = version
        workers[agent] = Task { [weak self] in await self?.run(agent, version: version, repeating: repeating) }
    }

    private func run(_ agent: ProviderID, version: UUID, repeating: Bool) async {
        guard let provider = providers[agent] else { return }
        if provider is CustomQuotaProvider {
            let index = enabledIDs.filter { providers[$0] is CustomQuotaProvider }.firstIndex(of: agent) ?? 0
            if index > 0 { do { try await clock.sleep(for: Double(index) * 0.25) } catch { return } }
        }
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
                update = QuotaUpdate(agent: agent, snapshot: snapshot, health: .ok, warnings: await customRunner.previews[agent]?.warnings, claudeConnection: agent == .claude ? claudeConnection : nil)
            } catch let caught {
                guard !(caught is CancellationError), !Task.isCancelled, versions[agent] == version else { return }
                error = (caught as? QuotaError) ?? .transient((caught as? CustomSourceError)?.message ?? "额度查询失败")
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

    private func loadInitialQuota(_ provider: any QuotaProviding, agent: ProviderID, version: UUID) async {
        guard snapshots[agent] == nil, let initial = provider as? any InitialQuotaProviding,
              let snapshot = await initial.initialQuota(), !Task.isCancelled,
              versions[agent] == version, snapshots[agent] == nil else { return }
        snapshots[agent] = snapshot
        let update = QuotaUpdate(agent: agent, snapshot: snapshot, health: .stale(lastSuccess: snapshot.fetchedAt))
        latest[agent] = update
        subscribers.values.forEach { $0.yield(update) }
    }

    private func delay(agent: ProviderID, error: QuotaError?) -> TimeInterval {
        if case .notConfigured = error { return 300 }
        let configured = intervals[agent] ?? 120
        if providers[agent] is CustomQuotaProvider { return max(1, configured) }
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
