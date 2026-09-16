import Foundation
import Darwin

public struct SessionPaths: Sendable {
    public var home: URL
    public var claude: URL
    public var codex: URL
    public var claudeDesktopMetadata: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, claude: URL? = nil,
                codex: URL? = nil, claudeDesktopMetadata: URL? = nil) {
        self.home = physicalURL(home)
        self.claude = physicalURL(claude ?? self.home.appendingPathComponent(".claude", isDirectory: true))
        self.codex = physicalURL(codex ?? self.home.appendingPathComponent(".codex", isDirectory: true))
        self.claudeDesktopMetadata = physicalURL(claudeDesktopMetadata ?? self.home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions", isDirectory: true))
    }
}

public protocol ProcessLiveness: Sendable {
    func isClaudeAlive(pid: Int32) -> Bool
}

public struct SystemProcessLiveness: ProcessLiveness {
    public init() {}
    public func isClaudeAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(pid, 0)
        guard result == 0 || errno == EPERM else { return false }
        // proc_info.h defines this as 4 * MAXPATHLEN; its expression macro is not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).lowercased().contains("claude")
    }
}

public struct ClaudeSessionDiagnostics: Codable, Sendable {
    public var processEntries = 0
    public var liveProcesses = 0
    public var transcripts = 0
    public var metadataEntries = 0
    public var returnedSessions = 0
    public var parsedBytes = 0
    public var elapsedMilliseconds: Double = 0
    public init() {}
}

public struct CodexSessionDiagnostics: Codable, Sendable {
    public var sqliteReadable = false
    public var sqliteThreads = 0
    public var usedDirectoryFallback = false
    public var transcripts = 0
    public var returnedSessions = 0
    public var parsedBytes = 0
    public var elapsedMilliseconds: Double = 0
    public init() {}
}

// JSON objects never leave the parsing actor; only typed Sendable state does.
typealias SessionJSON = [String: Any]

func sessionJSON(_ data: Data) -> SessionJSON? {
    guard data.count <= JSONLTailer.maximumLineBytes else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? SessionJSON
}
func sessionDate(_ value: Any?) -> Date? {
    if let text = value as? String { return DateParsing.iso8601(text) }
    if let number = value as? Double { return DateParsing.unixSeconds(number) }
    return nil
}
func sessionInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double < Double(Int.max) else { return nil }
    return Int(double)
}
func nonempty(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}
func cleanSessionText(_ text: String, limit: Int) -> String {
    String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
}
func firstPromptLine(_ text: String, limit: Int = 80) -> String {
    let first = text.split(whereSeparator: { $0.isNewline }).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    return cleanSessionText(String(first).trimmingCharacters(in: CharacterSet(charactersIn: "#-* >")), limit: limit)
}
func codexHeading(_ text: String, limit: Int = 40) -> String {
    let first = text.split(whereSeparator: { $0.isNewline }).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    let markers = CharacterSet(charactersIn: "#-*【】[]•> ").union(.whitespaces)
    let unmarked = String(first).trimmingCharacters(in: markers).replacingOccurrences(of: "】", with: "")
        
    let cleaned = cleanSessionText(unmarked, limit: Int.max)
    let boundaries = Set("（(【[《。！？；!?;")
    if let boundary = cleaned.firstIndex(where: { boundaries.contains($0) }), boundary != cleaned.startIndex {
        return String(cleaned[..<boundary].prefix(limit)).trimmingCharacters(in: .whitespaces)
    }
    guard cleaned.count > limit else { return cleaned }
    let prefix = String(cleaned.prefix(max(0, limit - 1)))
    let punctuation = Set("。！？；，,.!?;: ")
    if let boundary = prefix.lastIndex(where: { punctuation.contains($0) }), boundary != prefix.startIndex {
        return String(prefix[..<boundary]).trimmingCharacters(in: .whitespaces) + "…"
    }
    return prefix + "…"
}
func sessionPlan(_ entries: [SessionJSON]) -> PlanProgress {
    let current = entries.first { ["in_progress", "inProgress"].contains($0["status"] as? String ?? "") }
    let description = current.flatMap { nonempty($0["activeForm"] as? String) ?? nonempty($0["content"] as? String) ?? nonempty($0["step"] as? String) }
    return PlanProgress(completed: entries.filter { $0["status"] as? String == "completed" }.count,
                        total: entries.count, current: description.map { cleanSessionText($0, limit: 60) })
}
func sessionChildren(_ directory: URL) -> [URL] {
    autoreleasepool {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }
}
func sessionIsDirectory(_ url: URL) -> Bool {
    autoreleasepool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
    }
}
func sessionModified(_ url: URL) -> Date? {
    autoreleasepool {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
func sessionRegularFile(_ url: URL) -> Bool {
    autoreleasepool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false
    }
}
func sessionOrder(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
    lhs.lastActivityAt == rhs.lastActivityAt ? lhs.id < rhs.id : lhs.lastActivityAt > rhs.lastActivityAt
}

/// A subscription owns its watcher. Cancellation terminates FSEvents without changing M0's protocol.
func sessionChanges(paths: [String], accepts: @escaping @Sendable (String) -> Bool = { _ in true }) -> AsyncStream<Set<String>> {
    let watcher = FileWatcher(paths: paths)
    let pair = AsyncStream<Set<String>>.makeStream()
    let task = Task {
        for await changed in watcher.changes {
            guard !Task.isCancelled else { break }
            let relevant = changed.filter(accepts)
            if !relevant.isEmpty { pair.continuation.yield(relevant) }
        }
        watcher.cancel()
        pair.continuation.finish()
    }
    pair.continuation.onTermination = { _ in task.cancel(); watcher.cancel() }
    return pair.stream
}

/// Parent-directory events (including FSEvents recovery) invalidate descendants.
func sessionPathAffected(_ url: URL, by paths: Set<String>?) -> Bool {
    guard let paths else { return true }
    // Roots/index URLs and coalesced change paths are normalized at their input boundary.
    let path = url.path
    return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
}

struct SessionFileStamp: Equatable, Sendable {
    var identity: String
    var size: UInt64
    var modified: Date
    var changed: Date

    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        identity = "\(info.st_dev):\(info.st_ino)"
        size = UInt64(info.st_size)
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        changed = Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9)
    }
}

protocol SessionLogState: Sendable {
    init()
    mutating func consume(_ object: SessionJSON)
    var requiresEarlierContext: Bool { get }
}

extension SessionLogState {
    var requiresEarlierContext: Bool { false }
}

/// Owned by a provider, which serializes refreshes across the tailer's suspension point.
struct SessionLog<State: SessionLogState>: Sendable {
    var state = State()
    var warning: String?
    private(set) var tailer: JSONLTailer
    var identity: String?
    var size: UInt64 = 0
    private var stamp: SessionFileStamp?
    init(url: URL) { tailer = JSONLTailer(url: url, initialTailBytes: 1_048_576) }

    mutating func read(url: URL) async -> Int {
        guard let nextStamp = SessionFileStamp(url), stamp != nextStamp else { return 0 }
        let nextIdentity = nextStamp.identity
        let nextSize = nextStamp.size
        let rewritten = identity == nextIdentity && nextSize == size
        let initialRead = identity != nextIdentity || nextSize < size || rewritten
        if initialRead { state = State(); warning = nil }
        // Same-size rewrites need a fresh tailer; appends retain their offset and partial line.
        if rewritten {
            tailer = JSONLTailer(url: url, initialTailBytes: 1_048_576)
        }
        identity = nextIdentity
        size = nextSize
        var bytes = 0
        var tailBytes = 1_048_576
        while !Task.isCancelled {
            repeat {
                let before = await tailer.bytesReadTotal
                let lines = await tailer.readNewLines(maximumReadBytes: 262_144)
                bytes += await tailer.bytesReadTotal - before
                autoreleasepool {
                    for line in lines {
                        autoreleasepool {
                            if let object = sessionJSON(line) { state.consume(object) }
                            else { warning = "部分会话记录格式异常，已跳过" }
                        }
                    }
                }
            } while await tailer.hasMore && !Task.isCancelled
            if await tailer.skippedLines > 0 { warning = "已跳过超长或非 UTF-8 会话记录" }
            if await tailer.wasTruncated { warning = "会话记录已截断或替换，已重新读取" }
            // Recover a turn whose start fell outside the first tail. Only bootstrap/rotation
            // may backtrack; subsequent file events continue at the retained byte offset.
            guard initialRead, state.requiresEarlierContext, UInt64(tailBytes) < nextSize else { break }
            tailBytes = min(Int(clamping: nextSize), tailBytes <= Int.max / 2 ? tailBytes * 2 : Int.max)
            state = State()
            tailer = JSONLTailer(url: url, initialTailBytes: tailBytes)
        }
        if !Task.isCancelled, await tailer.lastReadSucceeded { stamp = nextStamp }
        return bytes
    }
}
