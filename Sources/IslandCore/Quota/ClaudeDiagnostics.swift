import Foundation

/// A closed schema: callers cannot pass tokens, paths, response bodies or error text.
public actor ClaudeDiagnostics {
    public enum Event: String, Codable, Sendable {
        case fetchStart, fetchEnd, httpEnd, credentialRead, credentialInvalidated
        case recoverEnter, recoverSkip, refresherStart, refresherEnd, refresherSkip, healthChange
        case sleep, wake, lock, unlock, displaySleep, displayWake, watchdog, watchdogRelaunch, retry
    }
    public enum Category: String, Codable, Sendable {
        case ok, transient, unauthorized, signedOut, notConfigured, decoding, cancelled, timeout
        case blocked, cooldown, window, credentialChanged, cliChanged, network, wakeGrace, backoff
        case refreshed, alreadyFresh, needsUserSetup, needsLogin, failed
        case stale, needsSetup, disabled, fetch, refresh
    }
    public enum Reason: String, Codable, Sendable {
        case earlyExit, timeout, loginScreen, setupScreen, cancelled, failure
    }
    public struct Record: Codable, Sendable {
        public let time: Date
        public let event: Event
        public let category: Category?
        public let statusCode: Int?
        public let present: Bool?
        public let expiresAt: Date?
        public let duration: TimeInterval?
        public let previous: Category?
        public let reason: Reason?
        public let provider: ProviderID?
    }
    public static let shared = ClaudeDiagnostics(directory: defaultDirectory)
    public static let disabled = ClaudeDiagnostics(directory: nil)
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentIsland/diagnostics")
    }
    private let directory: URL?
    private let limit: Int
    public init(directory: URL?, limit: Int = 1_048_576) {
        self.directory = directory; self.limit = max(1024, limit)
    }
    public func record(_ event: Event, at time: Date = Date(), category: Category? = nil,
                       statusCode: Int? = nil, present: Bool? = nil, expiresAt: Date? = nil,
                       duration: TimeInterval? = nil, previous: Category? = nil, reason: Reason? = nil,
                       provider: ProviderID? = nil) {
        guard let directory else { return }
        let record = Record(time: time, event: event, category: category, statusCode: statusCode,
                            present: present, expiresAt: expiresAt, duration: duration, previous: previous,
                            reason: reason, provider: provider)
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record); data.append(10)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("claude.jsonl")
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > limit {
                let previous = directory.appendingPathComponent("claude.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { /* Diagnostics must never interrupt recovery. No raw error logging. */ }
    }
    public func recentLines(count: Int = 200) -> [String] {
        guard let directory else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for name in ["claude.previous.jsonl", "claude.jsonl"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 10) {
                // Re-encoding the allowlisted fields prevents unknown fields in a damaged file
                // from being echoed by the diagnostic command.
                guard let record = try? decoder.decode(Record.self, from: Data(line)),
                      let clean = try? encoder.encode(record) else { continue }
                lines.append(String(decoding: clean, as: UTF8.self))
            }
        }
        return Array(lines.suffix(max(0, min(count, 200))))
    }
    static func category(_ error: any Error) -> Category {
        if error is CancellationError { return .cancelled }
        if ClaudeCredentialStore.isSignedOut(error) { return .signedOut }
        switch error as? QuotaError {
        case .unauthorized: return .unauthorized
        case .notConfigured: return .notConfigured
        case .decoding: return .decoding
        default: return .transient
        }
    }
    static func category(_ result: ClaudeRefreshResult) -> Category {
        switch result {
        case .refreshed: .refreshed
        case .alreadyFresh: .alreadyFresh
        case .needsUserSetup: .needsUserSetup
        case .needsLogin: .needsLogin
        case .failed: .failed
        }
    }
    static func reason(_ result: ClaudeRefreshResult) -> Reason? {
        switch result {
        case .refreshed, .alreadyFresh: nil
        case .needsUserSetup: .setupScreen
        case .needsLogin: .loginScreen
        case let .failed(message):
            if message.contains("超时") { .timeout }
            else if message.contains("取消") { .cancelled }
            else if message.contains("提前退出") || message.contains("输出中断") { .earlyExit }
            else { .failure }
        }
    }
    static func category(_ health: ProviderHealth) -> Category {
        switch health {
        case .ok: .ok
        case .stale: .stale
        case .needsSetup: .needsSetup
        case .failed: .failed
        case .disabled: .disabled
        }
    }
}
