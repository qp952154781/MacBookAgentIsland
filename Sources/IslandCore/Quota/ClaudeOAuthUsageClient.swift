import Foundation

public struct UsageHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let retryAfter: String?
    public init(statusCode: Int, data: Data = Data(), retryAfter: String? = nil) {
        self.statusCode = statusCode; self.data = data; self.retryAfter = retryAfter
    }
}

public protocol UsageHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> UsageHTTPResponse
}

private final class UsageRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct EphemeralUsageHTTPTransport: UsageHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> UsageHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: UsageRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.transient("Claude 额度响应无效") }
        return UsageHTTPResponse(statusCode: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }
}

public actor ClaudeOAuthUsageClient {
    public static let recoveringMessage = "正在自动恢复连接…"
    private let credentialsPresent: @Sendable () async -> Bool?
    private let credentials: ClaudeCredentialStore
    private let http: any UsageHTTPTransport
    private let refresher: any ClaudeRefreshing
    private let now: @Sendable () -> Date
    private let clock: any QuotaClock
    private let diagnostics: ClaudeDiagnostics
    private let modificationDate: @Sendable () async throws -> Date?
    private let cliVersion: @Sendable () async -> String?
    private var connection = ClaudeConnectionStatus()
    private var nextRefresh = Date.distantPast
    private var retryAfter = Date.distantPast
    private var successCooldown = false
    private var failures = 0
    private var loginFailures = 0
    private var blocked = false
    private var observedCredential: Int?
    private var observedModification: Date?
    private var observedCLI: String?
    private var observedEnvironment = false
    private var observedModificationDate = false
    private var refreshStarted: Date?
    private var inFlight: Task<QuotaSnapshot, any Error>?
    private var flightID: UUID?

    public init(credentialsPresent: @escaping @Sendable () async -> Bool? = { await ClaudeCredentialPresence().exists() },
                credentials: ClaudeCredentialStore = ClaudeCredentialStore(),
                http: any UsageHTTPTransport = EphemeralUsageHTTPTransport(),
                executor: any QuotaCommandExecuting = QuotaCommandExecutor(),
                locate: @escaping @Sendable () async -> URL? = { await ExecutableLocator.claudeCLI() },
                now: @escaping @Sendable () -> Date = { Date() },
                refresher: (any ClaudeRefreshing)? = nil,
                clock: any QuotaClock = SystemQuotaClock(), diagnostics: ClaudeDiagnostics = .disabled,
                modificationDate: @escaping @Sendable () async throws -> Date? = { nil },
                cliVersion: @escaping @Sendable () async -> String? = { nil }) {
        self.credentialsPresent = credentialsPresent
        self.credentials = credentials; self.http = http; self.now = now; self.clock = clock
        self.diagnostics = diagnostics; self.modificationDate = modificationDate; self.cliVersion = cliVersion
        self.refresher = refresher ?? ClaudeCLIRefresher(expiryReader: ClaudeKeychainExpiryReader(executor: executor),
            locate: locate, diagnostics: diagnostics)
    }
    public static func live() -> ClaudeOAuthUsageClient {
        ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(diagnostics: .shared), diagnostics: .shared,
            modificationDate: { try await ClaudeKeychainModificationReader().modificationDate() },
            cliVersion: {
                guard let url = await ExecutableLocator.claudeCLI() else { return nil }
                let resolved = url.resolvingSymlinksInPath()
                let date = try? resolved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return resolved.path + ":" + (date.map { String($0.timeIntervalSince1970) } ?? "")
            })
    }
    public func status() -> ClaudeConnectionStatus { connection }
    public func retryConnection() async {
        // Finish cancelling the previous attempt before clearing its retry gates.
        // Otherwise its late failure could immediately reinstate a block after manual retry.
        let previousID = flightID
        if let inFlight {
            inFlight.cancel()
            _ = try? await inFlight.value
            if flightID == previousID { self.inFlight = nil; flightID = nil }
        }
        // Explicit retry and lifecycle events also bypass a previous success cooldown.
        resetRecovery()
        await diagnostics.record(.retry, at: now())
        await credentials.invalidate()
    }
    private func resetRecovery() {
        blocked = false; failures = 0; loginFailures = 0; successCooldown = false
        nextRefresh = .distantPast; connection.nextRetryAt = nil; connection.requiresUserAction = false
    }
    public func fetchQuota(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void = { _ in }) async throws -> QuotaSnapshot {
        if let inFlight { return try await inFlight.value }
        let id = UUID()
        let task = Task {
            await diagnostics.record(.fetchStart, at: now())
            do {
                let value = try await ClaudeWatchdog.run(clock: clock, onTimeout: { [diagnostics, now] in
                    await diagnostics.record(.watchdog, at: now(), category: .fetch)
                }) { try await self.fetch(onStatus: onStatus) }
                await diagnostics.record(.fetchEnd, at: now(), category: .ok)
                return value
            } catch {
                if connection.isRefreshing {
                    await diagnostics.record(.refresherEnd, at: now(), category: error is ClaudeWatchdogTimeout ? .timeout : .cancelled,
                        duration: refreshStarted.map { max(0, now().timeIntervalSince($0)) })
                    refreshStarted = nil
                    if error is ClaudeWatchdogTimeout { scheduleFailure() }
                }
                connection.isRefreshing = false
                await onStatus(connection)
                await diagnostics.record(.fetchEnd, at: now(), category: error is ClaudeWatchdogTimeout ? .timeout : ClaudeDiagnostics.category(error))
                if error is ClaudeWatchdogTimeout { throw QuotaError.transient("Claude 额度查询超时，将自动重试") }
                throw error
            }
        }
        inFlight = task; flightID = id
        defer { if flightID == id { inFlight = nil; flightID = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func checkEnvironment() async throws {
        // Run once per quota poll. The attribute query never uses -w.
        do {
            let modification = try await modificationDate()
            try Task.checkCancellation()
            if observedModificationDate, modification != observedModification {
                resetRecovery(); await credentials.invalidate()
                await diagnostics.record(.retry, at: now(), category: .credentialChanged)
            }
            observedModification = modification; observedModificationDate = true
        } catch {
            try Task.checkCancellation()
            await diagnostics.record(.credentialRead, at: now(), category: .transient)
        }
        let version = await cliVersion()
        try Task.checkCancellation()
        if observedEnvironment, version != observedCLI {
            resetRecovery(); await credentials.invalidate()
            await diagnostics.record(.retry, at: now(), category: .cliChanged)
        }
        observedCLI = version; observedEnvironment = true
    }
    private func fetch(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot {
        try await checkEnvironment()
        var retried = false
        while true {
            try Task.checkCancellation()
            if retryAfter > now() { throw QuotaError.transient("Claude 额度请求过于频繁，请在 \(Int(min(ceil(retryAfter.timeIntervalSince(now())), 2_147_483_647))) 秒后重试") }
            if blocked { await credentials.invalidate() }
            let credential: ClaudeCredential
            do { credential = try await credentials.credentials() }
            catch let error as QuotaError {
                try Task.checkCancellation()
                if case .notConfigured = error {
                    connection = ClaudeConnectionStatus()
                    connection.credentialsMissing = true
                    connection.requiresUserAction = true; connection.result = .needsLogin
                    await onStatus(connection)
                    throw error
                }
                throw error
            }
            try Task.checkCancellation()
            if let observedCredential, observedCredential != credential.changeID {
                resetRecovery()
                await diagnostics.record(.retry, at: now(), category: .credentialChanged)
            }
            observedCredential = credential.changeID
            connection.credentialsMissing = nil
            connection.expiresAt = credential.expiresAt
            let expired = credential.expiresAt.map { $0 <= now() } ?? false
            if expired {
                connection.isRecovering = true
                await onStatus(connection)
                if !retried, try await recover(force: false, onStatus: onStatus) { retried = true; continue }
                throw recoveryError()
            }
            // Valid credentials always reach HTTP, regardless of recovery gates.
            connection.isRecovering = false; connection.requiresUserAction = false
            await onStatus(connection)
            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw QuotaError.transient("Claude 额度地址无效") }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            credential.authorize(&request)
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("AgentIsland/0.1.0", forHTTPHeaderField: "User-Agent")
            let response: UsageHTTPResponse
            do { response = try await http.send(request) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                await diagnostics.record(.httpEnd, at: now(), category: .transient)
                throw QuotaError.transient("Claude 额度网络请求失败")
            }
            try Task.checkCancellation()
            await diagnostics.record(.httpEnd, at: now(), statusCode: response.statusCode)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200:
                let snapshot = credential.redacted(try ClaudeUsageMapper.map(data: response.data, subscriptionType: credential.subscriptionType,
                    rateLimitTier: credential.rateLimitTier, fetchedAt: now()))
                if !retried, let expiry = credential.expiresAt, expiry.timeIntervalSince(now()) <= 1800 {
                    _ = try await recover(force: false, onStatus: onStatus)
                } else { await diagnostics.record(.recoverSkip, at: now(), category: .window) }
                try Task.checkCancellation()
                connection.isRecovering = false; connection.requiresUserAction = false
                await onStatus(connection)
                return snapshot
            case 401, 403:
                await credentials.invalidate()
                connection.isRecovering = true
                if !retried, try await recover(force: true, onStatus: onStatus) { retried = true; continue }
                throw recoveryError()
            case 429:
                let seconds = Self.retrySeconds(response.retryAfter, now: now()) ?? 120
                retryAfter = now().addingTimeInterval(seconds)
                throw QuotaError.transient("Claude 额度请求过于频繁，请在 \(Int(min(seconds.rounded(.up), 2_147_483_647))) 秒后重试")
            case 500...599: throw QuotaError.transient("Claude 额度服务暂时不可用")
            default: throw QuotaError.transient("Claude 额度请求失败（HTTP \(response.statusCode)）")
            }
        }
    }
    private func recoveryError() -> QuotaError {
        if connection.requiresUserAction { return .unauthorized(connection.recoveryMessage) }
        return .transient(Self.recoveringMessage)
    }
    private func recover(force: Bool, onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> Bool {
        try Task.checkCancellation()
        await diagnostics.record(.recoverEnter, at: now())
        try Task.checkCancellation()
        let valid = connection.expiresAt.map { $0 > now() } ?? false
        if now() < nextRefresh, !successCooldown || valid {
            if blocked, connection.isRecovering {
                switch connection.result {
                case .needsUserSetup: connection.requiresUserAction = true
                case .needsLogin: connection.requiresUserAction = loginFailures >= 3
                default: break
                }
            }
            await diagnostics.record(.recoverSkip, at: now(), category: blocked ? .blocked : .cooldown)
            await onStatus(connection)
            return false
        }
        // Recheck immediately before invoking even an injected refresher: a cached token
        // or an HTTP response must not authorize CLI startup after credential removal.
        // Unknown presence (e.g. during unlock) keeps the existing recovery path available.
        if await credentialsPresent() == false {
            await credentials.invalidate()
            connection = ClaudeConnectionStatus()
            connection.credentialsMissing = true
            connection.requiresUserAction = true; connection.result = .needsLogin
            await onStatus(connection)
            throw QuotaError.notConfigured(ClaudeCredentialStore.loginMessage)
        }
        try Task.checkCancellation()
        blocked = false; connection.isRefreshing = true
        await onStatus(connection)
        let started = now(); refreshStarted = started
        await diagnostics.record(.refresherStart, at: started)
        let result: ClaudeRefreshResult
        do {
            result = try await ClaudeWatchdog.run(clock: clock, onTimeout: { [diagnostics, now] in
                await diagnostics.record(.watchdog, at: now(), category: .refresh)
            }) { [refresher] in await refresher.refresh(force: force) }
        } catch {
            try Task.checkCancellation()
            result = .failed("Claude 自动续期超时")
        }
        try Task.checkCancellation()
        connection.isRefreshing = false
        connection.lastAttempt = now(); connection.result = result
        connection.requiresUserAction = false; successCooldown = false
        await diagnostics.record(.refresherEnd, at: now(), category: ClaudeDiagnostics.category(result),
                                 duration: max(0, now().timeIntervalSince(started)))
        try Task.checkCancellation()
        refreshStarted = nil
        var renewed = false
        switch result {
        case .refreshed, .alreadyFresh:
            // A successful CLI result is insufficient: verify the new credential before cooling down.
            await credentials.invalidate()
            if let current = try? await credentials.credentials() {
                try Task.checkCancellation()
                connection.expiresAt = current.expiresAt; observedCredential = current.changeID
                renewed = current.expiresAt.map { $0 > now() } ?? false
            }
            if renewed {
                failures = 0; loginFailures = 0; successCooldown = true
                nextRefresh = now().addingTimeInterval(1800); connection.isRecovering = false
            } else { scheduleFailure() }
        case .needsUserSetup:
            loginFailures = 0; blocked = true; connection.requiresUserAction = true
            nextRefresh = now().addingTimeInterval(1800)
        case .needsLogin:
            loginFailures += 1; blocked = true
            // Initial failure plus two subsequent automatic attempts.
            connection.requiresUserAction = loginFailures >= 3
            nextRefresh = now().addingTimeInterval(1800)
        case .failed:
            loginFailures = 0; scheduleFailure()
        }
        connection.nextRetryAt = nextRefresh
        await onStatus(connection)
        try Task.checkCancellation()
        return renewed
    }
    private func scheduleFailure() {
        let delays: [Double] = [120, 300, 900, 1800]
        nextRefresh = now().addingTimeInterval(delays[min(failures, 3)])
        connection.nextRetryAt = nextRefresh
        failures = min(failures + 1, 3)
    }
    static func retrySeconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let raw = value else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(value), number.isFinite, number >= 0 { return min(number, 1e12) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt
        for format in ["EEE, dd MMM yyyy HH:mm:ss z", "EEEE, dd-MMM-yy HH:mm:ss z", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}

public protocol ClaudeConnectionProviding: QuotaProviding {
    func fetchQuota(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot
    func retryConnection() async
}
public struct ClaudeQuotaProvider: ClaudeConnectionProviding {
    public let agent: ProviderID = .claude
    private let client: ClaudeOAuthUsageClient
    public init(client: ClaudeOAuthUsageClient = .live()) { self.client = client }
    public func fetchQuota() async throws -> QuotaSnapshot { try await client.fetchQuota() }
    public func fetchQuota(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot {
        try await client.fetchQuota(onStatus: onStatus)
    }
    public func retryConnection() async { await client.retryConnection() }
}
