import Foundation

public actor ClaudeSessionProvider: SessionProviding {
    public nonisolated let agent: ProviderID = .claude
    private let paths: SessionPaths
    private let refreshDirectory: URL
    private let refreshProject: String
    private let liveness: any ProcessLiveness
    private let clock: @Sendable () -> Date
    private let modelPreferences: (any ClaudeModelPersisting)?
    private var lastObservedModel: String?
    private var modelLoaded = false
    private var modelBootstrapAttempted = false
    private var warning: String?
    public func diagnosticMessage() async -> String? { warning }
    private var activeWindow: TimeInterval = 1800
    private var logs: [String: SessionLog<ClaudeTranscript>] = [:]
    private var fileStamps: [String: SessionFileStamp] = [:]
    private var sessionCache: [String: AgentSession] = [:]
    private var discovered: [String: URL] = [:]
    private var excludedIDs: Set<String> = []
    private var processes: [String: ClaudeProcessEntry] = [:]
    private var loaded = false
    private var processEntryCount = 0
    private var metadata: [String: DesktopEntry] = [:]
    private var metadataFiles: [String: URL] = [:]
    private var metadataRecords: [String: DesktopRecord] = [:]
    private var inFlight: Task<[AgentSession], Never>?
    public private(set) var diagnostics = ClaudeSessionDiagnostics()

    private struct DesktopEntry: Sendable {
        var title: String?
        var archived: Bool
        var date: Date
    }

    private struct DesktopRecord: Sendable {
        var stamp: SessionFileStamp
        var id: String
        var entry: DesktopEntry
    }

    public init(paths: SessionPaths = SessionPaths(), liveness: any ProcessLiveness = SystemProcessLiveness(),
                clock: @escaping @Sendable () -> Date = { Date() }, modelPreferences: (any ClaudeModelPersisting)? = nil) {
        self.paths = paths; self.liveness = liveness; self.clock = clock
        self.modelPreferences = modelPreferences
        refreshDirectory = physicalURL(ClaudeRefreshDirectory.url(home: paths.home))
        refreshProject = refreshDirectory.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
    }
    public nonisolated func changes() -> AsyncStream<Set<String>> {
        sessionChanges(paths: [paths.claude.appendingPathComponent("sessions").path,
                               paths.claude.appendingPathComponent("projects").path, paths.claudeDesktopMetadata.path]) { path in
            let url = URL(fileURLWithPath: path)
            return url.pathExtension.isEmpty || ["json", "jsonl"].contains(url.pathExtension)
        }
    }
    public func setActiveWindow(_ seconds: TimeInterval) { activeWindow = seconds }
    public func currentSessions() async -> [AgentSession] { await currentSessions(now: clock()) }
    public func parsedBytesLastScan() -> Int { diagnostics.parsedBytes }
    public func latestObservedModel() async -> String? { lastObservedModel }
    private func observeModel(_ model: String?) async {
        guard let model = nonempty(model)?.trimmingCharacters(in: .whitespacesAndNewlines), model != lastObservedModel else { return }
        lastObservedModel = model
        await modelPreferences?.saveModel(model)
    }
    public func currentSessions(now: Date) async -> [AgentSession] {
        await currentSessions(now: now, changedPaths: nil)
    }
    public func currentSessions(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.scan(now: now, changedPaths: changedPaths) }
        inFlight = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight = nil
        return result
    }

    private func refreshMetadata(changes: Set<String>?) {
        autoreleasepool {
            let discover = changes == nil || changes?.contains(where: {
                sessionPathAffected(paths.claudeDesktopMetadata, by: [$0]) ||
                    ($0.hasPrefix(paths.claudeDesktopMetadata.path + "/") && metadataFiles[$0] == nil)
            }) == true
            if discover {
                metadataFiles.removeAll()
                for first in sessionChildren(paths.claudeDesktopMetadata) where sessionIsDirectory(first) {
                    for second in sessionChildren(first) where sessionIsDirectory(second) {
                        for file in sessionChildren(second) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" && sessionRegularFile(file) {
                            metadataFiles[file.path] = file
                        }
                    }
                }
            }
            metadataRecords = metadataRecords.filter { metadataFiles[$0.key] != nil }
            for (path, file) in metadataFiles where discover || sessionPathAffected(file, by: changes) {
                guard let stamp = SessionFileStamp(file) else {
                    metadataRecords.removeValue(forKey: path); metadataFiles.removeValue(forKey: path)
                    continue
                }
                guard metadataRecords[path]?.stamp != stamp else { continue }
                metadataRecords.removeValue(forKey: path)
                guard let data = try? Data(contentsOf: file), let object = sessionJSON(data),
                      let id = nonempty(object["cliSessionId"] as? String) else { continue }
                let date = (object["lastActivityAt"] as? Double).flatMap(DateParsing.unixMilliseconds) ?? stamp.modified
                let entry = DesktopEntry(title: object["title"] as? String, archived: object["isArchived"] as? Bool == true, date: date)
                metadataRecords[path] = DesktopRecord(stamp: stamp, id: id, entry: entry)
            }
            metadata.removeAll()
            for path in metadataRecords.keys.sorted() {
                guard let record = metadataRecords[path] else { continue }
                if let existing = metadata[record.id], existing.date > record.entry.date { continue }
                metadata[record.id] = record.entry
            }
        }
    }

    private func scan(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        // Loading is serialized with scans, so an overlapping getter cannot overwrite
        // a newly parsed model with an earlier asynchronous preference read.
        if !modelLoaded {
            lastObservedModel = nonempty(await modelPreferences?.loadModel())
            modelLoaded = true
        }
        warning = nil
        let start = ContinuousClock.now
        var report = ClaudeSessionDiagnostics()
        // Normalize each unique input once after watcher/service coalescing, never per comparison.
        let changes = loaded ? changedPaths.map { Set($0.map(physicalPath)) } : nil
        var alive: Set<String> = []
        let processRoot = paths.claude.appendingPathComponent("sessions")
        let processChanged = changes == nil || changes?.contains(where: {
            sessionPathAffected(processRoot, by: [$0]) || $0.hasPrefix(processRoot.path + "/")
        }) == true
        if processChanged {
            processes.removeAll(); excludedIDs.removeAll()
            processEntryCount = 0
            // Filter before opening: key files, symlinks, and non-JSON entries are never read.
            for file in sessionChildren(paths.claude.appendingPathComponent("sessions")) where file.pathExtension == "json" && sessionRegularFile(file) {
                processEntryCount += 1
                guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(ClaudeProcessEntry.self, from: data),
                      entry.pid > 0, !entry.sessionId.isEmpty else { continue }
                if ClaudeRefreshDirectory.contains(entry.cwd, directory: refreshDirectory) { excludedIDs.insert(entry.sessionId); continue }
                let live = liveness.isClaudeAlive(pid: entry.pid)
                if processes[entry.sessionId] == nil || live { processes[entry.sessionId] = entry }
            }
        }
        report.processEntries = processEntryCount
        for entry in processes.values where liveness.isClaudeAlive(pid: entry.pid) {
            alive.insert(entry.sessionId); report.liveProcesses += 1
        }
        let metadataChanged = changes == nil || changes?.contains(where: {
            sessionPathAffected(paths.claudeDesktopMetadata, by: [$0]) || $0.hasPrefix(paths.claudeDesktopMetadata.path + "/")
        }) == true
        if metadataChanged { refreshMetadata(changes: changes) }
        report.metadataEntries = metadata.count
        // Known transcript appends do not enumerate project trees or desktop metadata.
        let knownPaths = Set(discovered.values.map(\.path))
        let projectRoot = paths.claude.appendingPathComponent("projects")
        let discover = changes == nil || changes?.contains(where: {
            sessionPathAffected(projectRoot, by: [$0]) ||
                ($0.hasPrefix(projectRoot.path + "/") && !knownPaths.contains($0))
        }) == true
        if discover {
            discovered.removeAll()
            for project in sessionChildren(paths.claude.appendingPathComponent("projects")) where sessionIsDirectory(project) {
                if project.lastPathComponent == refreshProject { continue }
                for file in sessionChildren(project) where file.pathExtension == "jsonl" && sessionRegularFile(file) {
                    let id = file.deletingPathExtension().lastPathComponent
                    if let existing = discovered[id], (sessionModified(existing) ?? .distantPast) > (sessionModified(file) ?? .distantPast) { continue }
                    discovered[id] = file
                }
            }
        }
        for (id, file) in discovered where discover || sessionPathAffected(file, by: changes) {
            fileStamps[id] = SessionFileStamp(file)
            if fileStamps[id] == nil { discovered.removeValue(forKey: id); logs.removeValue(forKey: id) }
        }
        fileStamps = fileStamps.filter { discovered[$0.key] != nil }
        loaded = true
        report.transcripts = discovered.count
        let eligible = Set(discovered.keys).union(alive).filter { id in
            !excludedIDs.contains(id) && metadata[id]?.archived != true && (alive.contains(id) || now.timeIntervalSince(fileStamps[id]?.modified ?? .distantPast) <= activeWindow)
        }
        let candidates = Set(eligible.sorted { left, right in
            let lhs = fileStamps[left]?.modified ?? .distantPast
            let rhs = fileStamps[right]?.modified ?? .distantPast
            if alive.contains(left) != alive.contains(right) { return alive.contains(left) }
            return lhs == rhs ? left < right : lhs > rhs
        }.prefix(50))
        if eligible.count > 50 { warning = "Claude 仅显示最近 50 个会话" }
        var sessions: [AgentSession] = []
        var observed: (model: String, modified: Date)?
        for id in candidates.sorted() {
            if Task.isCancelled { break }
            if let message = logs[id]?.warning { warning = message }
            if let cached = sessionCache[id], !discover, !processChanged, !metadataChanged,
               cached.isAlive == alive.contains(id),
               !(discovered[id].map({ sessionPathAffected($0, by: changes) }) ?? false),
               !(cached.phase != .idle && !cached.phase.isWorking && now.timeIntervalSince(cached.lastActivityAt) >= 1800) {
                sessions.append(cached)
                continue
            }
            var state = ClaudeTranscript()
            let process = processes[id]
            let modified = fileStamps[id]?.modified ?? process?.startedAt.flatMap(DateParsing.unixMilliseconds) ?? .distantPast
            if let file = discovered[id] {
                var log = logs[id] ?? SessionLog(url: file)
                if log.tailer.url != file { log = SessionLog(url: file) }
                log.state.modelWasObserved = false
                if sessionPathAffected(file, by: changes) || logs[id] == nil || log.tailer.url != logs[id]?.tailer.url {
                    report.parsedBytes += await log.read(url: file)
                }
                if let message = log.warning { warning = message }
                state = log.state
                logs[id] = log
            }
            if ClaudeRefreshDirectory.contains(state.cwd, directory: refreshDirectory) { continue }
            if state.modelWasObserved, let model = state.model,
               observed == nil || modified > (observed?.modified ?? .distantPast) {
                observed = (model, modified)
            }
            sessions.append(state.session(id: id, process: process, alive: alive.contains(id), desktopTitle: metadata[id]?.title, modified: modified, now: now))
        }
        await observeModel(observed?.model)
        if lastObservedModel == nil, !modelBootstrapAttempted, !Task.isCancelled {
            modelBootstrapAttempted = true
            // Discovery above only lists/stats files. Bootstrap reads one bounded tail, even
            // when that transcript is older than the active window or contains no model.
            let latest = discovered.keys.filter {
                !excludedIDs.contains($0) && now.timeIntervalSince(fileStamps[$0]?.modified ?? .distantPast) <= 30 * 86400
            }.sorted {
                let lhs = fileStamps[$0]?.modified ?? .distantPast
                let rhs = fileStamps[$1]?.modified ?? .distantPast
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.first
            if let id = latest, let file = discovered[id] {
                var log = logs[id] ?? SessionLog<ClaudeTranscript>(url: file)
                report.parsedBytes += await log.read(url: file)
                if !ClaudeRefreshDirectory.contains(log.state.cwd, directory: refreshDirectory) {
                    await observeModel(log.state.model)
                }
            }
        }
        logs = logs.filter { candidates.contains($0.key) }
        sessionCache = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
        sessions = Array(sessions.sorted(by: sessionOrder).prefix(50))
        report.returnedSessions = sessions.count
        let duration = start.duration(to: .now).components
        report.elapsedMilliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        diagnostics = report
        return sessions
    }
}
