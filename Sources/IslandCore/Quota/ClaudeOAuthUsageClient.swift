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

private enum CredentialModification: Equatable {
    case none, ownRefresh, external
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
    private let reachability: any ClaudeReachabilityChecking
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
    private var lastRefreshBeganAt: Date?
    private var lastRefreshEndedAt: Date?
    private var autoRefreshEnabled = true
    private var failureBackoffUntil: Date?
    private var networkRetryAt: Date?
    private var networkWaitStarted: Date?
    private var lastResumeAt: Date?
    private var resumeCycle = 0
    private var resumeCycleOpen = false
    private var refreshedResumeCycle: Int?
    private var signedOut = false
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
                reachability: any ClaudeReachabilityChecking = AssumedClaudeReachability(),
                modificationDate: @escaping @Sendable () async throws -> Date? = { nil },
                cliVersion: @escaping @Sendable () async -> String? = { nil }) {
        self.credentialsPresent = credentialsPresent
        self.credentials = credentials; self.http = http; self.now = now; self.clock = clock
        self.diagnostics = diagnostics; self.reachability = reachability
        self.modificationDate = modificationDate; self.cliVersion = cliVersion
        self.refresher = refresher ?? ClaudeCLIRefresher(expiryReader: ClaudeKeychainExpiryReader(executor: executor),
            locate: locate, diagnostics: diagnostics)
    }
    public static func live(reachability: any ClaudeReachabilityChecking = AssumedClaudeReachability()) -> ClaudeOAuthUsageClient {
        ClaudeOAuthUsageClient(credentials: ClaudeCredentialStore(diagnostics: .shared), diagnostics: .shared,
            reachability: reachability,
            modificationDate: { try await ClaudeKeychainModificationReader().modificationDate() },
            cliVersion: {
                guard let url = await ExecutableLocator.claudeCLI() else { return nil }
                let resolved = url.resolvingSymlinksInPath()
                let date = try? resolved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return resolved.path + ":" + (date.map { String($0.timeIntervalSince1970) } ?? "")
            })
    }
    public func status() -> ClaudeConnectionStatus { connection }
    public func setAutoRefreshEnabled(_ enabled: Bool) async {
        guard autoRefreshEnabled != enabled else { return }
        autoRefreshEnabled = enabled
        connection.autoRefreshEnabled = enabled
        if enabled {
            connection.nextRetryAt = nextRefreshDate()
        } else {
            networkRetryAt = nil; networkWaitStarted = nil; connection.nextRetryAt = nil
            if connection.isRefreshing, let inFlight {
                inFlight.cancel()
                _ = try? await inFlight.value
            }
        }
    }
    public func noteSuspension() { resumeCycleOpen = false }
    public func noteResume() {
        if !resumeCycleOpen { resumeCycle += 1; resumeCycleOpen = true }
        lastResumeAt = now()
    }
    public func retryConnection() async {
        // Finish cancelling the previous attempt before clearing its retry gates.
        // Otherwise its late failure could immediately reinstate a block after manual retry.
        let previousID = flightID
        if let inFlight {
            inFlight.cancel()
            _ = try? await inFlight.value
            if flightID == previousID { self.inFlight = nil; flightID = nil }
        }
        // An explicit user retry bypasses prior recovery gates, except the one-attempt
        // limit for the current wake cycle.
        resetRecovery()
        signedOut = false
        await diagnostics.record(.retry, at: now())
        await credentials.invalidate()
    }
    private func resetRecovery() {
        blocked = false; failures = 0; loginFailures = 0; successCooldown = false
        failureBackoffUntil = nil; networkRetryAt = nil; networkWaitStarted = nil
        refreshedResumeCycle = nil
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
                    let timedOut = error is ClaudeWatchdogTimeout
                    let ended = now()
                    rememberRefreshWindow(started: refreshStarted, ended: ended)
                    await diagnostics.record(.refresherEnd, at: ended, category: timedOut ? .timeout : .cancelled,
                        duration: refreshStarted.map { max(0, now().timeIntervalSince($0)) },
                        reason: timedOut ? .timeout : .cancelled)
                    refreshStarted = nil
                    scheduleFailure()
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
    private func checkEnvironment(includeCLI: Bool) async throws -> CredentialModification {
        var credentialModification = CredentialModification.none
        // Run once per quota poll. The attribute query never uses -w.
        do {
            let modification = try await modificationDate()
            try Task.checkCancellation()
            if observedModificationDate, modification != observedModification {
                let ownRefresh = modification.map(isOwnRefreshModification) ?? false
                credentialModification = ownRefresh ? .ownRefresh : .external
                if !ownRefresh {
                    resetRecovery()
                    await diagnostics.record(.retry, at: now(), category: .credentialChanged)
                }
                await credentials.invalidate()
            }
            observedModification = modification; observedModificationDate = true
        } catch {
            try Task.checkCancellation()
            await diagnostics.record(.credentialRead, at: now(), category: .transient)
        }
        guard includeCLI else { return credentialModification }
        let version = await cliVersion()
        try Task.checkCancellation()
        if observedEnvironment, version != observedCLI {
            resetRecovery(); await credentials.invalidate()
            await diagnostics.record(.retry, at: now(), category: .cliChanged)
        }
        observedCLI = version; observedEnvironment = true
        return credentialModification
    }
    private func fetch(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async throws -> QuotaSnapshot {
        // Once signed out, the frequent recovery poll only probes the keychain attribute.
        // A changed attribute clears this state; the following fetch performs the full CLI check.
        let credentialModification = try await checkEnvironment(includeCLI: !signedOut)
        if credentialModification == .external { signedOut = false }
        if signedOut {
            await markSignedOut(onStatus: onStatus)
            throw QuotaError.unauthorized(ClaudeCredentialStore.signedOutMessage)
        }
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
                    connection = ClaudeConnectionStatus(autoRefreshEnabled: autoRefreshEnabled)
                    connection.credentialsMissing = true
                    connection.requiresUserAction = true; connection.result = .needsLogin
                    await onStatus(connection)
                    throw error
                }
                if ClaudeCredentialStore.isSignedOut(error) {
                    signedOut = true
                    await markSignedOut(onStatus: onStatus)
                    throw error
                }
                throw error
            }
            try Task.checkCancellation()
            if let observedCredential, observedCredential != credential.changeID {
                if credentialModification != .ownRefresh {
                    resetRecovery()
                    await diagnostics.record(.retry, at: now(), category: .credentialChanged)
                }
            }
            observedCredential = credential.changeID
            connection.credentialsMissing = nil
            signedOut = false
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
    private func markSignedOut(onStatus: @escaping @Sendable (ClaudeConnectionStatus) async -> Void) async {
        connection = ClaudeConnectionStatus(autoRefreshEnabled: autoRefreshEnabled)
        connection.credentialsMissing = false
        connection.requiresUserAction = true
        connection.result = .needsLogin
        await onStatus(connection)
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
        if !autoRefreshEnabled {
            connection.autoRefreshEnabled = false; connection.nextRetryAt = nil
            await diagnostics.record(.refresherSkip, at: now(), category: .disabled)
            await onStatus(connection)
            return false
        }
        if let failureBackoffUntil, now() < failureBackoffUntil {
            connection.nextRetryAt = failureBackoffUntil
            await diagnostics.record(.refresherSkip, at: now(), category: .backoff)
            await onStatus(connection)
            return false
        }
        if let lastResumeAt {
            let graceEnd = lastResumeAt.addingTimeInterval(45)
            if now() < graceEnd {
                connection.nextRetryAt = graceEnd
                await diagnostics.record(.refresherSkip, at: now(), category: .wakeGrace)
                await onStatus(connection)
                return false
            }
        }
        if resumeCycleOpen, refreshedResumeCycle == resumeCycle {
            connection.nextRetryAt = nil
            await diagnostics.record(.refresherSkip, at: now(), category: .backoff)
            await onStatus(connection)
            return false
        }
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
        if let networkRetryAt, now() < networkRetryAt {
            connection.nextRetryAt = networkRetryAt
            await diagnostics.record(.refresherSkip, at: now(), category: .network)
            await onStatus(connection)
            return false
        }
        networkRetryAt = nil
        if await !reachability.isReachable() {
            let started = networkWaitStarted ?? now()
            networkWaitStarted = started
            if now().timeIntervalSince(started) < 600 {
                networkRetryAt = now().addingTimeInterval(15)
                connection.nextRetryAt = networkRetryAt
            } else {
                networkWaitStarted = nil
                connection.nextRetryAt = nil
            }
            await diagnostics.record(.refresherSkip, at: now(), category: .network)
            await onStatus(connection)
            return false
        }
        networkWaitStarted = nil; networkRetryAt = nil
        // Recheck immediately before invoking even an injected refresher: a cached token
        // or an HTTP response must not authorize CLI startup after credential removal.
        // Unknown presence (e.g. during unlock) keeps the existing recovery path available.
        if await credentialsPresent() == false {
            await credentials.invalidate()
            connection = ClaudeConnectionStatus(autoRefreshEnabled: autoRefreshEnabled)
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
        let ended = now()
        rememberRefreshWindow(started: started, ended: ended)
        await diagnostics.record(.refresherEnd, at: ended, category: ClaudeDiagnostics.category(result),
                                 duration: max(0, ended.timeIntervalSince(started)),
                                 reason: ClaudeDiagnostics.reason(result))
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
                failureBackoffUntil = nil
                nextRefresh = now().addingTimeInterval(1800); connection.isRecovering = false
            } else { scheduleFailure() }
        case .needsUserSetup:
            loginFailures = 0; blocked = true; connection.requiresUserAction = true
            nextRefresh = now().addingTimeInterval(1800)
        case .needsLogin:
            loginFailures += 1; blocked = true
            // Initial failure plus two subsequent automatic attempts.
            connection.requiresUserAction = loginFailures >= 3
            failureBackoffUntil = now().addingTimeInterval(1800)
            nextRefresh = failureBackoffUntil ?? now()
        case .failed:
            loginFailures = 0; scheduleFailure()
        }
        connection.nextRetryAt = nextRefreshDate()
        await onStatus(connection)
        try Task.checkCancellation()
        return renewed
    }
    private func scheduleFailure() {
        // Only a failed attempt closes the wake cycle: a successful refresh must not block
        // the next legitimate one, which is due when the token expires ~8 hours later.
        if resumeCycleOpen { refreshedResumeCycle = resumeCycle }
        failureBackoffUntil = now().addingTimeInterval(1800)
        nextRefresh = failureBackoffUntil ?? now()
        connection.nextRetryAt = nextRefreshDate()
        failures = min(failures + 1, 3)
    }
    private func nextRefreshDate() -> Date? {
        [failureBackoffUntil, networkRetryAt, nextRefresh == .distantPast ? nil : nextRefresh]
            .compactMap { $0 }.min()
    }
    private func rememberRefreshWindow(started: Date?, ended: Date) {
        guard let started else { return }
        lastRefreshBeganAt = started; lastRefreshEndedAt = ended
    }
    private func isOwnRefreshModification(_ date: Date) -> Bool {
        guard let began = lastRefreshBeganAt, let ended = lastRefreshEndedAt else { return false }
        // Keychain timestamps may have whole-second precision.
        return date >= began.addingTimeInterval(-1) && date <= ended.addingTimeInterval(1)
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
    func setAutoRefreshEnabled(_ enabled: Bool) async
    func noteSuspension() async
    func noteResume() async
}
public extension ClaudeConnectionProviding {
    func setAutoRefreshEnabled(_ enabled: Bool) async {}
    func noteSuspension() async {}
    func noteResume() async {}
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
    public func setAutoRefreshEnabled(_ enabled: Bool) async { await client.setAutoRefreshEnabled(enabled) }
    public func noteSuspension() async { await client.noteSuspension() }
    public func noteResume() async { await client.noteResume() }
}
