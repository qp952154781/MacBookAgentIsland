import Foundation
import SQLite3

public actor CodexSessionProvider: SessionProviding {
    public nonisolated let agent: ProviderID = .codex
    private let paths: SessionPaths
    private let clock: @Sendable () -> Date
    private var warning: String?
    public func diagnosticMessage() async -> String? { warning }
    private var activeWindow: TimeInterval = 1800
    private var logs: [String: SessionLog<CodexRollout>] = [:]
    private var fileStamps: [String: SessionFileStamp] = [:]
    private var sessionCache: [String: AgentSession] = [:]
    private var threadCache: [String: CodexThread] = [:]
    private var threads: [CodexThread] = []
    private var loaded = false
    private var inFlight: Task<[AgentSession], Never>?
    public private(set) var diagnostics = CodexSessionDiagnostics()

    public init(paths: SessionPaths = SessionPaths(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths; self.clock = clock
    }
    public nonisolated func changes() -> AsyncStream<Set<String>> {
        sessionChanges(paths: [paths.codex.path]) { [paths] path in
            let url = URL(fileURLWithPath: path), name = url.lastPathComponent
            let path = url.path
            // FSEvents reports physical paths; keep the cached root in that same form.
            let root = paths.codex
            let sessions = root.appendingPathComponent("sessions")
            return sessionPathAffected(root, by: [path]) || sessionPathAffected(sessions, by: [path]) ||
                (path.hasPrefix(sessions.path + "/") && (url.pathExtension.isEmpty ||
                    (name.hasPrefix("rollout-") && url.pathExtension == "jsonl"))) ||
                (url.deletingLastPathComponent().path == root.path && name.hasPrefix("state_") &&
                    (name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite-wal")))
        }
    }
    public func setActiveWindow(_ seconds: TimeInterval) { activeWindow = seconds }
    public func currentSessions() async -> [AgentSession] { await currentSessions(now: clock()) }
    public func parsedBytesLastScan() -> Int { diagnostics.parsedBytes }
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

    private func readThreads(now: Date) -> [CodexThread]? {
        let databases = sessionChildren(paths.codex).compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"), sessionRegularFile(url),
                  let version = Int(name.dropFirst(6)) else { return nil }
            return (version, url)
        }
        guard let url = databases.max(by: { $0.0 < $1.0 })?.1 else { return nil }
        // URL.absoluteString escapes spaces, '?' and '#' before adding SQLite's read-only query.
        let uri = url.absoluteString + "?mode=ro"
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else { return nil }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        // SELECT * tolerates missing optional columns in older schemas; names are read dynamically.
        let sql = "SELECT * FROM threads WHERE archived = 0 AND updated_at_ms > ? ORDER BY updated_at_ms DESC LIMIT 50"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000)
        var indices: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            if let name = sqlite3_column_name(statement, index) { indices[String(cString: name)] = index }
        }
        func string(_ name: String) -> String? {
            guard let index = indices[name], sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        }
        var threads: [CodexThread] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return threads }
            guard result == SQLITE_ROW else { return nil }
            guard let id = nonempty(string("id")) else { continue }
            let date = string("updated_at_ms").flatMap(Double.init).flatMap(DateParsing.unixMilliseconds) ?? .distantPast
            let rollout = nonempty(string("rollout_path")).map {
                // Index paths can be absolute or relative to this directory, regardless of
                // the caller's URL directory hint (which may be false for a symlink).
                physicalURL($0.hasPrefix("/") ? URL(fileURLWithPath: $0) : paths.codex.appendingPathComponent($0))
            }
            threads.append(CodexThread(id: id, rollout: rollout, updated: date, cwd: string("cwd"), source: string("source"),
                                       name: string("name"), title: string("title"), preview: string("preview"),
                                       firstUserMessage: string("first_user_message"), model: string("model")))
        }
    }

    private func directoryThreads(now: Date) -> [CodexThread] {
        let calendar = Calendar.current
        var threads: [CodexThread] = []
        for offset in [0, -1] {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let relative = String(format: "sessions/%04d/%02d/%02d", year, month, day)
            for file in sessionChildren(paths.codex.appendingPathComponent(relative)) where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" && sessionRegularFile(file) {
                let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
                guard UUID(uuidString: id) != nil else { continue }
                threads.append(CodexThread(id: id, rollout: file, updated: sessionModified(file) ?? .distantPast))
            }
        }
        return threads
    }

    private func scan(now: Date, changedPaths: Set<String>?) async -> [AgentSession] {
        warning = nil
        let start = ContinuousClock.now
        var report = CodexSessionDiagnostics()
        // Normalize only the coalesced scan request, not each watcher callback/comparison.
        let changes = loaded ? changedPaths.map { Set($0.map(physicalPath)) } : nil
        let knownPaths = Set(threads.compactMap { $0.rollout?.path })
        let discover = changes == nil || changes?.contains(where: { !knownPaths.contains($0) }) == true
        if discover {
            let indexed = readThreads(now: now)
            report.sqliteReadable = indexed != nil
            report.sqliteThreads = indexed?.count ?? 0
            report.usedDirectoryFallback = indexed == nil
            threads = indexed ?? directoryThreads(now: now)
        } else {
            report.sqliteReadable = diagnostics.sqliteReadable
            report.sqliteThreads = diagnostics.sqliteThreads
            report.usedDirectoryFallback = diagnostics.usedDirectoryFallback
        }
        if report.usedDirectoryFallback { warning = "Codex 索引不存在、被锁或损坏，已改读会话目录" }
        loaded = true
        let rolloutPaths = Set(threads.compactMap { $0.rollout?.path })
        fileStamps = fileStamps.filter { rolloutPaths.contains($0.key) }
        for thread in threads {
            guard let url = thread.rollout, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            if fileStamps[url.path] == nil || sessionPathAffected(url, by: changes) {
                fileStamps[url.path] = SessionFileStamp(url)
            }
        }
        report.transcripts = fileStamps.count
        var sessions: [String: AgentSession] = [:]
        var retained: Set<String> = []
        for thread in threads.sorted(by: { $0.updated > $1.updated }).prefix(50) {
            if Task.isCancelled { break }
            let modified = thread.rollout.flatMap { fileStamps[$0.path]?.modified } ?? thread.updated
            guard now.timeIntervalSince(modified) <= activeWindow else { continue }
            retained.insert(thread.id)
            if let message = logs[thread.id]?.warning { warning = message }
            if let cached = sessionCache[thread.id], changes != nil, threadCache[thread.id] == thread,
               cached.lastActivityAt == modified,
               !(thread.rollout.map { sessionPathAffected($0, by: changes) } ?? false),
               cached.phase != .compacting,
               !(cached.phase.isWorking && now.timeIntervalSince(modified) >= 1200) {
                sessions[thread.id] = cached
                continue
            }
            var state = CodexRollout()
            // Do not follow arbitrary index paths to credentials or other file types.
            if let url = thread.rollout, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-"), fileStamps[url.path] != nil {
                var log = logs[thread.id] ?? SessionLog(url: url)
                if log.tailer.url != url { log = SessionLog(url: url) }
                if sessionPathAffected(url, by: changes) || logs[thread.id] == nil || log.tailer.url != logs[thread.id]?.tailer.url {
                    report.parsedBytes += await log.read(url: url)
                }
                if let message = log.warning { warning = message }
                state = log.state
                logs[thread.id] = log
            }
            let session = state.session(thread: thread, modified: modified, now: now)
            if let previous = sessions[thread.id], previous.lastActivityAt > modified { continue }
            sessions[thread.id] = session
        }
        logs = logs.filter { retained.contains($0.key) }
        sessionCache = sessions
        threadCache = threads.reduce(into: [:]) { $0[$1.id] = $1 }
        let result = Array(sessions.values.sorted(by: sessionOrder).prefix(50))
        report.returnedSessions = result.count
        let duration = start.duration(to: .now).components
        report.elapsedMilliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        diagnostics = report
        return result
    }
}
