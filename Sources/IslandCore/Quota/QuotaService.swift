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

private actor QuotaTaskCompletionRace {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
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
    private let workerCancellationTimeout: TimeInterval
    private let watchdogPollInterval: TimeInterval
    private var workers: [ProviderID: Task<Void, Never>] = [:]
    private var versions: [ProviderID: UUID] = [:]
    private var workerStartedAt: [ProviderID: Date] = [:]
    private var lastUpdates: [ProviderID: Date] = [:]
    private var watchdogTask: Task<Void, Never>?
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
                clock: any QuotaClock = SystemQuotaClock(), customRunner: CustomCommandRunner = .shared,
                allowsCustomCommands: Bool = true, diagnostics: ClaudeDiagnostics = .disabled,
                workerCancellationTimeout: TimeInterval = 10, watchdogPollInterval: TimeInterval = 60,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }) {
        self.customRunner = customRunner; self.allowsCustomCommands = allowsCustomCommands
        var byAgent: [ProviderID: any QuotaProviding] = [:]
        for provider in providers { byAgent[provider.agent] = provider }
        self.enabledIDs = providers.map(\.agent)
        self.diagnostics = diagnostics; self.providers = byAgent; self.intervals = intervals; self.clock = clock
        self.workerCancellationTimeout = workerCancellationTimeout.isFinite ? max(0.01, workerCancellationTimeout) : 10
        self.watchdogPollInterval = watchdogPollInterval.isFinite ? max(0.01, watchdogPollInterval) : 60
        self.jitter = jitter
    }

    public func setCustomSources(_ sources: [CustomSource]) async {
        guard allowsCustomCommands else { return }
        guard customSources != sources else { reconcileWorkers(); return }
        let changed = customSources.filter { old in !sources.contains(old) }.map(\.id)
        customSources = sources
        let tasks = changed.compactMap { workers.removeValue(forKey: $0) }
        for id in changed {
            versions[id] = nil; providers[id] = nil; latest[id] = nil; snapshots[id] = nil
            workerStartedAt[id] = nil; lastUpdates[id] = nil
        }
        tasks.forEach { $0.cancel() }
        for id in changed { await customRunner.cancel(source: id); await customRunner.forget(id) }
        await waitForCancellation(of: tasks)
        guard customSources == sources else { reconcileWorkers(); return }
        for source in sources {
            providers[source.id] = CustomQuotaProvider(source: source, runner: customRunner)
            intervals[source.id] = source.interval
        }
        // setEnabledProviders follows this reconciliation and launches added/replaced workers.
        enabledIDs.removeAll { changed.contains($0) || providers[$0] == nil }
        reconcileWorkers()
    }

    public func setEnabledProviders(_ ids: [ProviderID]) async {
        let next = ids.filter { providers[$0] != nil }
        guard next != enabledIDs else { reconcileWorkers(); return }
        let removed = enabledIDs.filter { !next.contains($0) }
        enabledIDs = next
        providerVersion = UUID()
        let token = providerVersion
        let cancelled = removed.compactMap { workers.removeValue(forKey: $0) }
        for id in removed {
            versions[id] = nil; latest[id] = nil; snapshots[id] = nil; failures[id] = nil
            workerStartedAt[id] = nil; lastUpdates[id] = nil
        }
        cancelled.forEach { $0.cancel() }
        for id in removed where customSources.contains(where: { $0.id == id }) { await customRunner.cancel(source: id) }
        await waitForCancellation(of: cancelled)
        guard token == providerVersion else { reconcileWorkers(); return }
        reconcileWorkers()
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
        guard !running else { reconcileWorkers(); return }
        running = true; lifecycle = UUID()
        guard !suspended else { return }
        for agent in enabledIDs where workers[agent] == nil { launch(agent, repeating: true) }
        startWatchdog()
    }

    /// Preserve subscribers while hidden; wake resumes the existing store connection.
    public func setSuspended(_ value: Bool) async {
        guard suspended != value else {
            if !value { reconcileWorkers() }
            return
        }
        suspended = value; lifecycle = UUID()
        if allowsCustomCommands { await customRunner.setSuspended(value) }
        if value {
            stopWatchdog()
            let tasks = Array(workers.values)
            workers.removeAll(); versions.removeAll()
            tasks.forEach { $0.cancel() }
            await waitForCancellation(of: tasks)
        } else if running {
            for agent in enabledIDs where workers[agent] == nil { launch(agent, repeating: true) }
            startWatchdog()
        }
    }

    public func stop() async {
        running = false; lifecycle = UUID()
        stopWatchdog()
        let tasks = Array(workers.values)
        workers.removeAll(); versions.removeAll()
        tasks.forEach { $0.cancel() }
        subscribers.values.forEach { $0.finish() }; subscribers.removeAll()
        if allowsCustomCommands { await customRunner.cancelAll() }
        await waitForCancellation(of: tasks)
    }

    /// Interrupts the selected sleep/query and waits only up to a fixed bound before replacing it.
    /// While stopped this performs one query; it does not start a scheduling loop.
    public func refreshNow(agent: ProviderID? = nil) async {
        guard !suspended else { return }
        let selected = agent.map { [$0] } ?? enabledIDs
        let epoch = lifecycle
        var replaced: [(ProviderID, UUID, Task<Void, Never>?)] = []
        for key in selected where enabledIDs.contains(key) && providers[key] != nil {
            let token = UUID(), task = workers.removeValue(forKey: key)
            versions[key] = token
            task?.cancel()
            replaced.append((key, token, task))
        }
        await withTaskGroup(of: (ProviderID, UUID).self) { group in
            for (key, token, task) in replaced {
                let timeout = workerCancellationTimeout
                group.addTask {
                    _ = await Self.waitForCompletion(of: task, timeout: timeout)
                    return (key, token)
                }
            }
            for await (key, token) in group {
                guard epoch == lifecycle, versions[key] == token else {
                    if versions[key] == token { workers[key] = nil; versions[key] = nil }
                    continue
                }
                guard !suspended, enabledIDs.contains(key), providers[key] != nil else {
                    workers[key] = nil; versions[key] = nil
                    continue
                }
                launch(key, repeating: running)
            }
        }
        reconcileWorkers()
    }

    public func retryClaudeConnection() async {
        guard enabledIDs.contains(.claude) else { return }
        await (providers[.claude] as? any ClaudeConnectionProviding)?.retryConnection()
        await refreshNow(agent: .claude)
    }
    public func setClaudeAutoRefresh(_ enabled: Bool) async {
        await (providers[.claude] as? any ClaudeConnectionProviding)?.setAutoRefreshEnabled(enabled)
    }
    public func noteClaudeSuspension() async {
        await (providers[.claude] as? any ClaudeConnectionProviding)?.noteSuspension()
    }
    public func noteClaudeResume() async {
        await (providers[.claude] as? any ClaudeConnectionProviding)?.noteResume()
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
        workerStartedAt[agent] = clock.now()
        workers[agent] = Task { [weak self] in await self?.run(agent, version: version, repeating: repeating) }
    }

    private func run(_ agent: ProviderID, version: UUID, repeating: Bool) async {
        defer {
            if versions[agent] == version {
                workers[agent] = nil
                versions[agent] = nil
                workerStartedAt[agent] = nil
            }
        }
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
            lastUpdates[agent] = clock.now()
            await recordHealth(update)
            guard versions[agent] == version, !Task.isCancelled else { return }
            latest[agent] = update
            subscribers.values.forEach { $0.yield(update) }
            guard repeating else { break }
            do { try await clock.sleep(for: delay(agent: agent, error: error)) }
            catch { break }
        }
        await bootstrap
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
        if agent == .claude, claudeConnection?.credentialsMissing == false,
           claudeConnection?.requiresUserAction == true, claudeConnection?.result == .needsLogin {
            return 30
        }
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

    private nonisolated static func waitForCompletion(
        of task: Task<Void, Never>?, timeout: TimeInterval
    ) async -> Bool {
        guard let task else { return true }
        let race = QuotaTaskCompletionRace()
        let completion = Task {
            await task.value
            await race.resolve(true)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            await race.resolve(false)
        }
        let completed = await race.value()
        if completed { deadline.cancel() } else { completion.cancel() }
        return completed
    }

    private func waitForCancellation(of tasks: [Task<Void, Never>]) async {
        let timeout = workerCancellationTimeout
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { _ = await Self.waitForCompletion(of: task, timeout: timeout) }
            }
        }
    }

    private func reconcileWorkers() {
        guard running, !suspended else { return }
        for agent in enabledIDs where providers[agent] != nil && workers[agent] == nil {
            launch(agent, repeating: true)
        }
        startWatchdog()
    }

    private func startWatchdog() {
        guard running, !suspended, watchdogTask == nil else { return }
        let epoch = lifecycle
        watchdogTask = Task { [weak self] in await self?.watchdogLoop(epoch: epoch) }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func watchdogLoop(epoch: UUID) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(watchdogPollInterval)) }
            catch { break }
            guard epoch == lifecycle, running, !suspended else { break }
            await watchdogTick()
        }
        if epoch == lifecycle { watchdogTask = nil }
    }

    private func watchdogTick() async {
        guard running, !suspended else { return }
        let now = clock.now()
        for agent in enabledIDs where providers[agent] != nil {
            let configured = intervals[agent] ?? 120
            let interval = configured.isFinite ? max(1, configured) : 60
            let threshold = max(3 * interval, 600)
            let reference = [lastUpdates[agent], workerStartedAt[agent]].compactMap { $0 }.max()
            let stale = reference.map { now.timeIntervalSince($0) > threshold } ?? false
            guard stale || workers[agent] == nil else { continue }

            let old = workers.removeValue(forKey: agent)
            versions[agent] = nil
            old?.cancel()
            launch(agent, repeating: true)
            await diagnostics.record(.watchdogRelaunch, at: now, provider: agent)
        }
    }

    func activeWorkerIDs() -> Set<ProviderID> { Set(workers.keys) }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
