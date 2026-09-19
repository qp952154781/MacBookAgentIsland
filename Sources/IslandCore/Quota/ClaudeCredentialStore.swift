import Foundation

public struct ClaudeCredential: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?
    public let scopes: [String]

    private enum RootKeys: String, CodingKey { case claudeAiOauth }
    // refreshToken is deliberately absent: the decoder never materializes it as a property.
    private enum Keys: String, CodingKey { case accessToken, expiresAt, subscriptionType, rateLimitTier, scopes }
    public init(from decoder: any Decoder) throws {
        do {
            let root = try decoder.container(keyedBy: RootKeys.self)
            let values = try root.nestedContainer(keyedBy: Keys.self, forKey: .claudeAiOauth)
            let token = try values.decode(String.self, forKey: .accessToken)
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuotaError.unauthorized(ClaudeCredentialStore.signedOutMessage)
            }
            guard !token.contains("\r"), !token.contains("\n") else { throw QuotaError.decoding("Claude 凭据格式无效") }
            accessToken = token
            expiresAt = (try? values.decode(Double.self, forKey: .expiresAt)).flatMap(DateParsing.unixMilliseconds)
            subscriptionType = try? values.decode(String.self, forKey: .subscriptionType)
            rateLimitTier = try? values.decode(String.self, forKey: .rateLimitTier)
            scopes = (try? values.decode([String].self, forKey: .scopes)) ?? []
        } catch let error as QuotaError { throw error }
        catch { throw QuotaError.decoding("Claude 凭据格式无效") }
    }
    public var description: String { "ClaudeCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credential": "<redacted>"]) }

    var changeID: Int { var hasher = Hasher(); hasher.combine(accessToken); hasher.combine(expiresAt); return hasher.finalize() }

    func authorize(_ request: inout URLRequest) { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
    func redacted(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
        var result = snapshot
        func clean(_ string: String) -> String { string.replacingOccurrences(of: accessToken, with: "<redacted>") }
        result.plan = result.plan.map(clean)
        for index in result.windows.indices {
            result.windows[index].id = clean(result.windows[index].id)
            result.windows[index].label = clean(result.windows[index].label)
        }
        return result
    }
}

public actor ClaudeCredentialStore {
    public static let loginMessage = "在终端运行一次 claude auth login 以连接 Claude 额度"
    public static let expiredMessage = "Claude 登录已过期，请在终端重新运行 claude auth login"
    public static let signedOutMessage = "Claude 已退出登录，请重新运行 claude auth login"
    public static func isSignedOut(_ error: any Error) -> Bool {
        error as? QuotaError == .unauthorized(signedOutMessage)
    }
    private let executor: any QuotaCommandExecuting
    private let readFallback: @Sendable () async throws -> Data?
    private let now: @Sendable () -> Date
    private let diagnostics: ClaudeDiagnostics
    private var cached: ClaudeCredential?
    private var generation = 0

    public init(executor: any QuotaCommandExecuting = QuotaCommandExecutor(),
                now: @escaping @Sendable () -> Date = { Date() },
                diagnostics: ClaudeDiagnostics = .disabled,
                readFallback: @escaping @Sendable () async throws -> Data? = {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return try Data(contentsOf: url)
                }) {
        self.executor = executor; self.now = now; self.readFallback = readFallback; self.diagnostics = diagnostics
    }

    public func invalidate() { cached = nil; generation += 1 }

    public func credentials() async throws -> ClaudeCredential {
        do {
            for attempt in 0...1 {
                let version = generation
                let credential = try await readCredentials()
                if version != generation {
                    await diagnostics.record(.credentialInvalidated, at: now())
                    if attempt == 0 { continue }
                    throw QuotaError.transient("Claude 登录信息正在更新，请稍后重试")
                }
                if credential.expiresAt != nil { cached = credential }
                await diagnostics.record(.credentialRead, at: now(), category: .ok, present: true, expiresAt: credential.expiresAt)
                return credential
            }
            throw QuotaError.transient("Claude 登录信息正在更新，请稍后重试")
        } catch {
            let category = ClaudeDiagnostics.category(error)
            await diagnostics.record(.credentialRead, at: now(), category: category,
                                     present: category == .notConfigured ? false : nil)
            throw error
        }
    }

    private func readCredentials() async throws -> ClaudeCredential {
        try Task.checkCancellation()
        if let cached, let expiry = cached.expiresAt, expiry > now() { return cached }
        cached = nil
        let output: QuotaCommandOutput
        do {
            output = try await executor.run(executableURL: URL(fileURLWithPath: "/usr/bin/security"),
                                            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 5)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw QuotaError.transient("无法读取 Claude 登录信息")
        }
        try Task.checkCancellation()
        let data: Data
        if output.exitCode == 44 || output.itemNotFound {
            do {
                guard let fallback = try await readFallback() else { throw QuotaError.notConfigured(Self.loginMessage) }
                data = fallback
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let quota = error as? QuotaError { throw quota }
                throw QuotaError.transient("无法读取 Claude 登录文件")
            }
        } else if output.exitCode == 0 { data = output.stdout }
        else { throw QuotaError.transient("无法读取 Claude 登录信息") }
        let credential: ClaudeCredential
        do { credential = try JSONDecoder().decode(ClaudeCredential.self, from: data) }
        catch let error as QuotaError { throw error }
        catch { throw QuotaError.decoding("Claude 凭据格式无效") }
        try Task.checkCancellation()
        return credential
    }
}

/// Expiry-only decoding never materializes access or refresh tokens.
public struct ClaudeKeychainExpiryReader: ClaudeExpiryReading {
    private let executor: any QuotaCommandExecuting
    public init(executor: any QuotaCommandExecuting = QuotaCommandExecutor()) { self.executor = executor }
    public func expiry() async throws -> Date? {
        let output = try await executor.run(executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 5)
        if output.exitCode == 44 || output.itemNotFound { return nil }
        guard output.exitCode == 0 else { throw QuotaError.transient("无法读取 Claude 登录有效期") }
        struct Envelope: Decodable {
            struct OAuth: Decodable {
                let expiresAt: Double?
                let signedOut: Bool
                private enum CodingKeys: String, CodingKey { case accessToken, expiresAt }
                init(from decoder: any Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    let token = try values.decode(String.self, forKey: .accessToken)
                    signedOut = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    expiresAt = try? values.decode(Double.self, forKey: .expiresAt)
                }
            }
            let claudeAiOauth: OAuth
        }
        let value: Envelope
        do { value = try JSONDecoder().decode(Envelope.self, from: output.stdout) }
        catch { throw QuotaError.decoding("Claude 登录有效期格式无效") }
        if value.claudeAiOauth.signedOut {
            throw QuotaError.unauthorized(ClaudeCredentialStore.signedOutMessage)
        }
        guard !output.stdout.isEmpty else {
            throw QuotaError.decoding("Claude 登录有效期格式无效")
        }
        return value.claudeAiOauth.expiresAt.flatMap(DateParsing.unixMilliseconds)
    }
}

/// Attributes only: never asks security to print the password and never retains other attributes.
public struct ClaudeKeychainModificationReader: Sendable {
    private let executor: any QuotaCommandExecuting
    public init(executor: any QuotaCommandExecuting = QuotaCommandExecutor()) { self.executor = executor }
    public func modificationDate() async throws -> Date? {
        let output = try await executor.run(executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Claude Code-credentials"], timeout: 5)
        if output.exitCode == 44 || output.itemNotFound { return nil }
        guard output.exitCode == 0 else { throw QuotaError.transient("无法读取 Claude 登录更新时间") }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("\"mdat\"") }),
              let range = line.range(of: "[0-9]{14}Z", options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return formatter.date(from: String(line[range]))
    }
}
