import Foundation

public struct SessionUpdate: Sendable, Equatable {
    public var warnings: [AgentKind: String] = [:]
    public var sessions: [AgentSession]
    public var events: [IslandEvent]
    public var codexTokenCountChanged: Bool
    public init(sessions: [AgentSession], events: [IslandEvent], codexTokenCountChanged: Bool = false) {
        self.sessions = sessions; self.events = events
        self.codexTokenCountChanged = codexTokenCountChanged
    }
}

/// Work counts are independent of published updates and contain no wall-clock diagnostics.
public struct SessionRescanMetrics: Sendable {
    public var sessionRescans = 0
    public var sessionRescansSkipped = 0
    public var parsedBytesTotal = 0
    public var updatesPublished = 0
}

public actor SessionService: SessionServicing {
    private struct Pending {
        var paths: Set<String> = []
        var full = false
        mutating func merge(_ changed: Set<String>?) {
            if let changed { if !full { paths.formUnion(changed) } }
            else { full = true; paths.removeAll() }
        }
    }
    private struct Result: Sendable {
        var agent: AgentKind
        var sessions: [AgentSession]
        var warning: String?
        var bytes: Int
        var finished: ContinuousClock.Instant
    }
    private let origin: ContinuousClock.Instant
    private let scheduler: any SessionScheduler
    private let providers: [any SessionProviding]
    private let clock: @Sendable () -> Date
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    private var delayTask: Task<Void, Never>?
    private var delayDeadline: ContinuousClock.Instant?
    private var pending: [AgentKind: Pending] = [:]
    private var lastScans: [AgentKind: ContinuousClock.Instant] = [:]
    private var hiddenSince: ContinuousClock.Instant?
    private var cached: [AgentKind: [AgentSession]] = [:]
    private var warnings: [AgentKind: String] = [:]
    private var continuations: [UUID: AsyncStream<SessionUpdate>.Continuation] = [:]
    private var sessions: [AgentSession] = []
    private var deduper = EventDeduper()
    public private(set) var refreshCounts: [AgentKind: Int] = [:]
    public private(set) var metrics = SessionRescanMetrics()
    private var running = false
    private var generation = 0
    private var hasLoaded = false

    public init(providers: [any SessionProviding], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(providers: providers, clock: clock, scheduler: SystemSessionScheduler())
    }

    init(providers: [any SessionProviding], clock: @escaping @Sendable () -> Date = { Date() },
         scheduler: any SessionScheduler) {
        self.providers = providers; self.clock = clock
        self.scheduler = scheduler; self.origin = scheduler.now()
    }
    deinit {
        for task in tasks { task.cancel() }
        refreshTask?.cancel(); delayTask?.cancel()
        for continuation in continuations.values { continuation.finish() }
    }
    public func setActiveWindow(_ seconds: TimeInterval) async {
        for provider in providers { await provider.setActiveWindow(seconds) }
        if running { await refreshNow() }
    }

    /// Events still coalesce while hidden; no file-driven scan can bypass this deadline.
    public func setVisible(_ visible: Bool) async {
        guard visible == (hiddenSince != nil) else { return }
        hiddenSince = visible ? nil : scheduler.now()
        if visible {
            lastScans.removeAll()
            if running { for provider in providers { enqueue(agent: provider.agent, paths: nil) } }
        }
        delayTask?.cancel()
    }

    public func updates() -> AsyncStream<SessionUpdate> {
        let id = UUID()
        let pair = AsyncStream<SessionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        if hasLoaded {
            var update = SessionUpdate(sessions: sessions, events: [])
            update.warnings = warnings
            pair.continuation.yield(update)
        }
        return pair.stream
    }
    private func removeSubscriber(_ id: UUID) { continuations.removeValue(forKey: id) }

    public func start() async {
        guard !running else { return }
        running = true
        hasLoaded = false
        for provider in providers {
            let changes = provider.changes(), agent = provider.agent
            tasks.append(Task { [weak self] in
                for await paths in changes {
                    guard !Task.isCancelled else { break }
                    await self?.changed(agent: agent, paths: paths)
                }
            })
        }
        tasks.append(Task { [weak self, scheduler] in
            while !Task.isCancelled {
                do { try await scheduler.sleep(until: scheduler.now().advanced(by: .seconds(30))) } catch { break }
                await self?.reconcile()
            }
        })
        await refreshNow()
    }

    func changed(agent: AgentKind, paths: Set<String>) {
        guard running else { return }
        enqueue(agent: agent, paths: paths.isEmpty ? nil : paths)
    }
    /// Wait for already enqueued work without requesting another full scan.
    func waitForPendingRefresh() async { await refreshTask?.value }

    private func reconcile() {
        guard running else { return }
        for provider in providers { enqueue(agent: provider.agent, paths: nil) }
    }

    public func stop() async {
        running = false
        generation += 1
        let stoppedTasks = tasks, stoppedRefresh = refreshTask
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        refreshTask?.cancel(); delayTask?.cancel()
        refreshTask = nil; delayTask = nil; delayDeadline = nil
        pending.removeAll(); lastScans.removeAll()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
        for task in stoppedTasks { await task.value }
        await stoppedRefresh?.value
    }

    /// Explicit reconciliation also respects provider limits. Wake is the sole immediate override.
    public func refreshNow() async {
        for provider in providers { enqueue(agent: provider.agent, paths: nil) }
        await refreshTask?.value
    }

    private func deadline(for agent: AgentKind) -> ContinuousClock.Instant {
        if let hiddenSince {
            return max(hiddenSince, lastScans[agent] ?? hiddenSince).advanced(by: .seconds(30))
        }
        return lastScans[agent]?.advanced(by: .milliseconds(500)) ?? origin
    }

    private func enqueue(agent: AgentKind, paths: Set<String>?) {
        if pending[agent] != nil || deadline(for: agent) > scheduler.now() {
            metrics.sessionRescansSkipped += 1
        }
        pending[agent, default: Pending()].merge(paths)
        // Only an earlier provider deadline needs to wake the scheduler. Same-provider bursts
        // (especially while hidden) merge without cancelling/recreating the timer.
        if let delayDeadline, deadline(for: agent) < delayDeadline { delayTask?.cancel() }
        guard refreshTask == nil else { return }
        let token = generation
        refreshTask = Task { [weak self] in await self?.refreshLoop(generation: token) }
    }

    private func refreshLoop(generation token: Int) async {
        defer { if token == generation { refreshTask = nil; delayTask = nil; delayDeadline = nil } }
        while !pending.isEmpty, token == generation, !Task.isCancelled {
            let nowInstant = scheduler.now()
            let due = providers.filter { pending[$0.agent] != nil && deadline(for: $0.agent) <= nowInstant }
            if due.isEmpty {
                guard let next = pending.keys.map({ deadline(for: $0) }).min() else { break }
                let delay = Task<Void, Never> { [scheduler] in
                    do { try await scheduler.sleep(until: next) } catch {}
                }
                delayTask = delay
                delayDeadline = next
                await delay.value
                delayTask = nil; delayDeadline = nil
                continue
            }
            let now = clock()
            let requests = due.map { provider in
                let request = pending.removeValue(forKey: provider.agent) ?? Pending(full: true)
                lastScans[provider.agent] = scheduler.now()
                refreshCounts[provider.agent, default: 0] += 1
                metrics.sessionRescans += 1
                return (provider, request.full ? nil : Optional(request.paths))
            }
            let results = await withTaskGroup(of: Result.self) { group in
                for (provider, paths) in requests {
                    group.addTask { [scheduler] in
                        let values = await provider.currentSessions(now: now, changedPaths: paths)
                        return Result(agent: provider.agent, sessions: values,
                                      warning: await provider.diagnosticMessage(), bytes: await provider.parsedBytesLastScan(), finished: scheduler.now())
                    }
                }
                var results: [Result] = []
                for await value in group { results.append(value) }
                return results
            }
            guard token == generation, !Task.isCancelled else { return }
            let previousWarnings = warnings
            for result in results {
                // Include provider scheduling/IO time in the cooldown so executor contention
                // cannot shorten the actual interval between successive scans below 500 ms.
                lastScans[result.agent] = result.finished
                cached[result.agent] = result.sessions
                warnings[result.agent] = result.warning
                metrics.parsedBytesTotal += result.bytes
            }
            let combined = cached.values.flatMap { $0 }.sorted(by: sessionOrder)
            // Timing/byte counters never participate in observable equality. One-shot event flags
            // are computed only after the persistent sessions/warnings actually change.
            guard !hasLoaded || combined != sessions || previousWarnings != warnings else { continue }
            let events = deduper.filter(detectSessionEvents(old: sessions, new: combined, now: now), now: now)
            let changed = hasLoaded && combined.contains { next in
                next.agent == .codex && next.tokenCountRevision != nil &&
                    sessions.first(where: { $0.id == next.id })?.tokenCountRevision != next.tokenCountRevision
            }
            hasLoaded = true
            sessions = combined
            var update = SessionUpdate(sessions: sessions, events: events, codexTokenCountChanged: changed)
            update.warnings = warnings
            metrics.updatesPublished += 1
            for continuation in continuations.values { continuation.yield(update) }
        }
    }
}
