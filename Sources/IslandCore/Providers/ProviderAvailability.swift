import Foundation

/// Evidence contains only existence results; nil means keychain presence is unknown.
public struct ProviderDetection: Equatable, Sendable {
    public var installed: [ProviderID: Bool]
    public var claudeCredentialsPresent: Bool?
    public init(installed: [ProviderID: Bool] = [:], claudeCredentialsPresent: Bool? = nil) {
        self.installed = installed; self.claudeCredentialsPresent = claudeCredentialsPresent
    }
}

public struct ProviderState: Equatable, Sendable, Identifiable, Encodable {
    public let id: ProviderID
    public let name: String
    public let detected: Bool
    public let override: Bool?
    public let enabled: Bool
    public let quotaAvailable: Bool
    public let sessionsAvailable: Bool
    public let quotaReason: Reason
    public let sessionsReason: Reason
    public let thirdPartyBackend: Bool
    public enum Reason: String, Sendable, Encodable {
        case available, notDetected, disabledByUser, thirdPartyBackend, unsupported
    }
    public var statusLabel: String {
        thirdPartyBackend ? "第三方后端 · 仅会话" : detected ? "已检测到" : "未检测到"
    }
    public var hasContent: Bool { quotaAvailable || sessionsAvailable }

    public init(descriptor: ProviderDescriptor, detection: ProviderDetection, override: Bool?, latestClaudeModel: String?) {
        id = descriptor.id; name = descriptor.displayName
        detected = detection.installed[id] ?? false
        self.override = override; enabled = override ?? detected
        thirdPartyBackend = id == .claude && Self.isThirdParty(credentialsPresent: detection.claudeCredentialsPresent, model: latestClaudeModel)
        quotaAvailable = enabled && descriptor.hasQuota && !thirdPartyBackend
        sessionsAvailable = enabled && descriptor.hasSessions
        let isEnabled = enabled, isDetected = detected
        func reason(supported: Bool, thirdParty: Bool = false) -> Reason {
            if override == false { return .disabledByUser }
            if !isEnabled { return .notDetected }
            if !supported { return .unsupported }
            if thirdParty { return .thirdPartyBackend }
            return isDetected ? .available : .notDetected
        }
        quotaReason = reason(supported: descriptor.hasQuota, thirdParty: thirdPartyBackend)
        sessionsReason = reason(supported: descriptor.hasSessions)
    }
    public static func isThirdParty(credentialsPresent: Bool?, model: String?) -> Bool {
        guard credentialsPresent == false,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return false }
        return !model.hasPrefix("claude-")
    }
    enum CodingKeys: String, CodingKey {
        case id, name, detected, override, enabled, quotaAvailable, sessionsAvailable, quotaReason, sessionsReason, thirdPartyBackend
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(detected, forKey: .detected); try c.encode(override, forKey: .override)
        try c.encode(enabled, forKey: .enabled); try c.encode(quotaAvailable, forKey: .quotaAvailable)
        try c.encode(sessionsAvailable, forKey: .sessionsAvailable)
        try c.encode(quotaReason, forKey: .quotaReason); try c.encode(sessionsReason, forKey: .sessionsReason)
        try c.encode(thirdPartyBackend, forKey: .thirdPartyBackend)
    }
}

/// Declarations are extensible; runtime presentation and services consume these resolved rows.
public enum ProviderAvailability {
    public static func resolve(declarations: [ProviderDescriptor] = ProviderRegistry.ordered,
                               detection: ProviderDetection, overrides: [ProviderID: Bool] = [:],
                               latestClaudeModel: String? = nil) -> [ProviderState] {
        declarations.map { ProviderState(descriptor: $0, detection: detection, override: overrides[$0.id], latestClaudeModel: latestClaudeModel) }
    }
}

public protocol ProviderDetecting: Sendable { func detect() async -> ProviderDetection }

public struct ProviderDetector: ProviderDetecting {
    private let home: URL
    private let credentials: ClaudeCredentialPresence
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, diagnosticHome: Bool = false,
                executor: any QuotaCommandExecuting = QuotaCommandExecutor()) {
        self.home = physicalURL(home)
        self.credentials = ClaudeCredentialPresence(home: home, useKeychain: !diagnosticHome, executor: executor)
    }
    public func detect() async -> ProviderDetection {
        func directory(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: physicalURL(home.appendingPathComponent(name)).path,
                                                  isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let claude = directory(".claude")
        let codex = directory(".codex")
        // Bundled executables alone do not mean the user has ever used Codex.
        return await ProviderDetection(installed: [.claude: claude, .codex: codex],
                                       claudeCredentialsPresent: credentials.exists())
    }
}

/// Existence only: never requests or parses password contents.
public struct ClaudeCredentialPresence: Sendable {
    private let home: URL
    private let useKeychain: Bool
    private let executor: any QuotaCommandExecuting
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, useKeychain: Bool = true,
                executor: any QuotaCommandExecuting = QuotaCommandExecutor()) {
        self.home = physicalURL(home); self.useKeychain = useKeychain; self.executor = executor
    }
    public func exists() async -> Bool? {
        if FileManager.default.fileExists(atPath: physicalURL(home.appendingPathComponent(".claude/.credentials.json")).path) { return true }
        guard useKeychain else { return false }
        guard let result = try? await executor.run(executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-s", "Claude Code-credentials"], timeout: 5) else { return nil }
        if result.exitCode == 0 { return true }
        if result.exitCode == 44 || result.itemNotFound { return false }
        return nil
    }
}
