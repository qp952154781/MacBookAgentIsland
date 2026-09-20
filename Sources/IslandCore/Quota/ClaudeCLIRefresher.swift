import Foundation
import Darwin

public enum ClaudeRefreshDirectory {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AgentIsland/claude-refresh", isDirectory: true)
    }
    public static func contains(_ cwd: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        contains(cwd, directory: physicalURL(url(home: physicalURL(home))))
    }

    // Providers cache this physical directory at initialization, outside scan loops.
    static func contains(_ cwd: String?, directory: URL) -> Bool {
        guard let cwd, cwd.hasPrefix("/") else { return false }
        return cwd == directory.path || physicalURL(URL(fileURLWithPath: cwd)).path == directory.path
    }
}

public enum ClaudeRefreshResult: Sendable, Equatable, Codable {
    case refreshed(Date), alreadyFresh, needsUserSetup(String), needsLogin, failed(String)
    public var message: String {
        switch self {
        case .refreshed: "自动续期成功"
        case .alreadyFresh: "登录仍然有效"
        case let .needsUserSetup(reason): reason
        case .needsLogin: "Claude 登录已失效，请重新登录"
        case let .failed(reason): reason
        }
    }
}

public struct ClaudeConnectionStatus: Sendable, Equatable, Codable {
    public static let automaticRefreshDisabledMessage = "Claude 登录已过期，自动续期已关闭"
    public var credentialsMissing: Bool?
    public var isRecovering = false
    public var isRefreshing = false
    public var requiresUserAction = false
    public var expiresAt: Date?
    public var lastAttempt: Date?
    public var nextRetryAt: Date?
    public var result: ClaudeRefreshResult?
    public var autoRefreshEnabled: Bool
    public init(autoRefreshEnabled: Bool = true) { self.autoRefreshEnabled = autoRefreshEnabled }
    public var recoveryMessage: String {
        if credentialsMissing == true { return "未连接 · 请在终端运行 claude auth login" }
        if !autoRefreshEnabled, isRecovering { return Self.automaticRefreshDisabledMessage }
        if requiresUserAction, case .needsLogin = result { return "Claude 登录已失效，请重新登录" }
        if requiresUserAction, case .needsUserSetup = result {
            return "请打开终端完成 Claude Code 设置，岛会每 30 分钟自动重试"
        }
        return ClaudeOAuthUsageClient.recoveringMessage
    }
}

public protocol ClaudeExpiryReading: Sendable {
    func expiry() async throws -> Date?
}
public protocol ClaudeRefreshing: Sendable {
    func refresh(force: Bool) async -> ClaudeRefreshResult
}
public protocol ClaudePTY: Sendable {
    func start(executable: URL, directory: URL) async throws -> AsyncThrowingStream<Data, any Error>
    func send(_ text: String) async throws
    /// Must reap the child and close the PTY before returning, including on cancellation.
    /// Graceful cleanup sends ESC then /exit only after /usage was successfully written;
    /// before that point cleanup must never write input.
    func finish(graceful: Bool) async
}

public actor ClaudeCLIRefresher: ClaudeRefreshing {
    private let credentialsPresent: @Sendable () async -> Bool?
    private let expiryReader: any ClaudeExpiryReading
    private let makePTY: @Sendable () -> any ClaudePTY
    private let locate: @Sendable () async -> URL?
    private let directory: URL
    private let timeout: TimeInterval
    private let clock: any QuotaClock
    private let diagnostics: ClaudeDiagnostics
    private var inFlight: Task<ClaudeRefreshResult, Never>?
    public init(credentialsPresent: @escaping @Sendable () async -> Bool? = { await ClaudeCredentialPresence().exists() },
                expiryReader: any ClaudeExpiryReading,
                makePTY: @escaping @Sendable () -> any ClaudePTY = { ClaudePTYProcess() },
                locate: @escaping @Sendable () async -> URL? = { await ExecutableLocator.claudeCLI() },
                directory: URL = ClaudeRefreshDirectory.url(), timeout: TimeInterval = 45,
                clock: any QuotaClock = SystemQuotaClock(), diagnostics: ClaudeDiagnostics = .disabled) {
        self.credentialsPresent = credentialsPresent
        self.expiryReader = expiryReader; self.makePTY = makePTY; self.locate = locate
        self.directory = directory; self.timeout = timeout; self.clock = clock; self.diagnostics = diagnostics
    }
    public func refresh(force: Bool = false) async -> ClaudeRefreshResult {
        if let inFlight { return await inFlight.value }
        let task = Task {
            do {
                return try await ClaudeWatchdog.run(clock: clock, onTimeout: { [diagnostics, clock] in
                    await diagnostics.record(.watchdog, at: clock.now(), category: .refresh)
                }) { await self.perform(force: force) }
            } catch { return ClaudeRefreshResult.failed("Claude 自动续期超时或已取消") }
        }
        inFlight = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight = nil
        return result
    }
    private func perform(force: Bool) async -> ClaudeRefreshResult {
        let pty = makePTY()
        let result = await withTaskGroup(of: ClaudeRefreshResult.self) { group in
            group.addTask { [credentialsPresent, expiryReader, locate, directory, clock] in
                do {
                    try Task.checkCancellation()
                    let before = try await expiryReader.expiry()
                    let wasValid = before.map { $0 > clock.now() } ?? false
                    if !force, let before, before.timeIntervalSince(clock.now()) > 1800 { return .alreadyFresh }
                    // A temporarily unavailable keychain is not evidence of a missing login.
                    if await credentialsPresent() == false { return .needsLogin }
                    try Task.checkCancellation()
                    guard let executable = await locate() else { return .needsUserSetup("未找到 Claude Code，请先安装并完成首次设置") }
                    try Task.checkCancellation()
                    let stream = try await pty.start(executable: executable, directory: directory)
                    return try await Self.interact(stream: stream, pty: pty, reader: expiryReader, wasValid: wasValid, clock: clock)
                } catch {
                    if ClaudeCredentialStore.isSignedOut(error) { return .needsLogin }
                    return .failed(Task.isCancelled ? "自动续期已取消" : "无法完成 Claude 自动续期")
                }
            }
            group.addTask { [timeout] in
                // Reserve the final five seconds for graceful exit / TERM / KILL.
                try? await Task.sleep(for: .seconds(max(0.01, timeout - 5)))
                return .failed("Claude 自动续期超时")
            }
            let first = await group.next() ?? .failed("Claude 自动续期已取消")
            group.cancelAll()
            // Closing the stream also wakes an output consumer on cancellation or timeout.
            // The transport permits graceful input only after a successful /usage write.
            await pty.finish(graceful: true)
            return first
        }
        return result
    }
    private static func interact(stream: AsyncThrowingStream<Data, any Error>, pty: any ClaudePTY,
                                 reader: any ClaudeExpiryReading, wasValid: Bool, clock: any QuotaClock) async throws -> ClaudeRefreshResult {
        let events = AsyncStream<RefreshEvent>.makeStream(bufferingPolicy: .bufferingOldest(8192))
        return try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll(); events.continuation.finish() }
            group.addTask {
                do {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        if case .dropped = events.continuation.yield(.output(chunk)) {
                            await pty.finish(graceful: true)
                            events.continuation.finish(); return
                        }
                    }
                } catch { /* A closed or failed transport ends the interaction without input. */ }
                events.continuation.yield(.ended)
            }
            var settleTimerPending = false
            var gate = ClaudePTYWriteGate()
            var lastOutput = ContinuousClock.now
            // Parsing, permission checks and writes share one consumer. No timer can retain
            // a stale ready flag while a different task recognizes a setup dialog.
            for await event in events.stream {
                try Task.checkCancellation()
                switch event {
                case let .output(chunk):
                    gate.consume(chunk); lastOutput = .now
                    if let result = gate.result {
                        await pty.finish(graceful: true)
                        return result
                    }
                    if !gate.usageSent, !settleTimerPending {
                        settleTimerPending = true
                        group.addTask {
                            try await Task.sleep(for: .milliseconds(200))
                            events.continuation.yield(.tick)
                        }
                    }
                case .tick:
                    settleTimerPending = false
                    let remaining = Duration.milliseconds(200) - lastOutput.duration(to: .now)
                    if remaining > .zero {
                        settleTimerPending = true
                        group.addTask {
                            try await Task.sleep(for: remaining)
                            events.continuation.yield(.tick)
                        }
                    } else if gate.beginUsage() {
                        try await pty.send("/usage\r")
                        group.addTask {
                            try await clock.sleep(for: 20)
                            events.continuation.yield(.usageTimedOut)
                        }
                        group.addTask {
                            do {
                                while !Task.isCancelled {
                                    try await clock.sleep(for: 0.5)
                                    if let expiry = try await reader.expiry(),
                                       expiry.timeIntervalSince(clock.now()) >= 300 {
                                        try Task.checkCancellation()
                                        events.continuation.yield(.renewed(expiry)); return
                                    }
                                }
                            } catch {
                                events.continuation.yield(ClaudeCredentialStore.isSignedOut(error) ? .signedOut : .ended)
                            }
                        }
                    }
                case let .renewed(expiry): return wasValid ? .alreadyFresh : .refreshed(expiry)
                case .signedOut: return .needsLogin
                case .usageTimedOut: return .failed("Claude 自动续期超时")
                case .ended: return .failed("Claude 续期进程提前退出")
                }
            }
            return .failed("Claude 续期终端输出中断")
        }
    }
}

private enum RefreshEvent: Sendable {
    case output(Data), tick, renewed(Date), signedOut, usageTimedOut, ended
}
