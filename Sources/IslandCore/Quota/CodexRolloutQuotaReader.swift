import Foundation
import SQLite3

public protocol CodexRolloutReading: Sendable {
    func fetchQuota() async throws -> QuotaSnapshot
}

public actor CodexRolloutQuotaReader: CodexRolloutReading {
    private let directory: URL
    private let now: @Sendable () -> Date
    private let candidateLimit: Int
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                candidateLimit: Int = 8, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.candidateLimit = max(1, candidateLimit); self.now = now
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let current = now()
        let indexed = indexedPaths()
        let paths = indexed.isEmpty ? scannedPaths(now: current) : indexed
        guard !paths.isEmpty else { throw QuotaError.notConfigured("未找到 Codex rollout") }
        var latest: QuotaSnapshot?
        for path in paths {
            try Task.checkCancellation()
            guard let data = readTail(path) else { continue }
            if let snapshot = Self.parse(data, now: current), latest == nil || snapshot.fetchedAt > (latest?.fetchedAt ?? .distantPast) {
                latest = snapshot
            }
        }
        guard let latest else { throw QuotaError.decoding("Codex rollout 中没有可用额度") }
        return latest
    }

    public static func parse(_ data: Data, now: Date) -> QuotaSnapshot? {
        var latest: QuotaSnapshot?
        for line in data.split(separator: 10) {
            autoreleasepool {
                guard line.count <= JSONLTailer.maximumLineBytes else { return }
                guard let root = try? QuotaJSON.parse(Data(line)), root["type"].string == "event_msg",
                      root["payload"]["type"].string == "token_count",
                      let timestamp = root["timestamp"].string.flatMap(DateParsing.iso8601),
                      root["payload"]["rate_limits"].object != nil else { return }
                let bucket = root["payload"]["rate_limits"]
                var windows: [QuotaWindow] = []
                for slot in ["primary", "secondary"] {
                    let value = bucket[slot]
                    guard let used = value["used_percent"].number else { continue }
                    let minutes = value["window_minutes"].integer
                    let (kind, label) = CodexQuotaMapper.windowType(minutes: minutes, extra: false)
                    let reset = value["resets_at"].number.flatMap(DateParsing.unixSeconds)
                        ?? value["resets_in_seconds"].number.map { timestamp.addingTimeInterval($0) }
                    let expired = reset.map { $0 <= now } ?? false
                    windows.append(QuotaWindow(id: "\(bucket["limit_id"].string ?? "codex").\(slot)", kind: kind,
                                               label: label, usedPercent: expired ? 0 : used, windowMinutes: minutes,
                                               resetsAt: expired ? nil : reset))
                }
                guard !windows.isEmpty else { return }
                let snapshot = QuotaSnapshot(agent: .codex, plan: bucket["plan_type"].string,
                                             windows: sortedQuotaWindows(windows), source: .codexRollout, fetchedAt: timestamp)
                if latest == nil || timestamp >= (latest?.fetchedAt ?? .distantPast) { latest = snapshot }
            }
        }
        return latest
    }

    private func isRollout(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        return url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
            && resolved.lastPathComponent.hasPrefix("rollout-") && resolved.pathExtension == "jsonl"
    }

    private func indexedPaths() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let databases = files.compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", url.resolvingSymlinksInPath().pathExtension == "sqlite",
                  name.hasPrefix("state_"), let version = Int(name.dropFirst(6)) else { return nil }
            return (version, url)
        }.sorted { $0.0 > $1.0 }
        for (_, url) in databases {
            var db: OpaquePointer?
            let uri = url.absoluteString + "?mode=ro"
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads ORDER BY updated_at_ms DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(candidateLimit))
            var paths: [URL] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                let path = URL(fileURLWithPath: String(cString: text))
                if isRollout(path), FileManager.default.isReadableFile(atPath: path.path) { paths.append(path) }
            }
            if !paths.isEmpty { return byModificationDate(paths) }
        }
        return []
    }

    private func scannedPaths(now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var paths: [URL] = []
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let path = directory.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", year, month, date))
            let files = (try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            paths += files.filter(isRollout)
        }
        return Array(byModificationDate(paths).prefix(candidateLimit))
    }

    private func byModificationDate(_ paths: [URL]) -> [URL] {
        let dated: [(URL, Date)] = paths.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? Date.distantPast)
        }
        return dated.sorted { left, right in
            left.1 == right.1 ? left.0.path < right.0.path : left.1 > right.1
        }.map { $0.0 }
    }

    private func readTail(_ path: URL) -> Data? {
        guard isRollout(path), let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd(), limit: UInt64 = 512 * 1024
            let offset = size > limit ? size - limit : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: Int(min(size, limit))) ?? Data()
            // Drop the boundary line when starting mid-file; never read earlier file contents.
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return nil }
                data.removeSubrange(...newline)
            }
            return data
        } catch { return nil }
    }
}

public struct CodexQuotaProvider: InitialQuotaProviding {
    public let agent: ProviderID = .codex
    private let appServer: @Sendable () async throws -> QuotaSnapshot
    private let rollout: any CodexRolloutReading
    public init(client: CodexAppServerClient = CodexAppServerClient(), rollout: any CodexRolloutReading = CodexRolloutQuotaReader()) {
        self.appServer = { try await client.fetchQuota() }; self.rollout = rollout
    }
    public init(appServer: @escaping @Sendable () async throws -> QuotaSnapshot, rollout: any CodexRolloutReading) {
        self.appServer = appServer; self.rollout = rollout
    }
    public func initialQuota() async -> QuotaSnapshot? { try? await rollout.fetchQuota() }
    public func fetchQuota() async throws -> QuotaSnapshot {
        do { return try await appServer() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let primaryError = error
            let missing: Bool
            if case .notConfigured = error as? QuotaError { missing = true } else { missing = false }
            do { return try await rollout.fetchQuota() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if missing, case .notConfigured = error as? QuotaError { throw QuotaError.notConfigured("未找到 Codex") }
                throw primaryError
            }
        }
    }
}
