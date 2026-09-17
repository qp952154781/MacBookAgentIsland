import Foundation
import IslandCore

struct DumpQuota {
    private struct Entry: Encodable {
        let health: ProviderHealth
        let snapshot: QuotaSnapshot?
        enum CodingKeys: String, CodingKey { case health, snapshot }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(health, forKey: .health)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
    private struct Report: Encodable {
        let generatedAt: Date
        let claude: Entry
        let codex: Entry
    }

    @MainActor static func run(home: URL?) async -> Int32 {
        let states = await DumpProviders.states(home: home)
        let enabled = Set(states.filter { $0.quotaAvailable && $0.detected }.map(\.id))
        guard let home else { return await run(enabled: enabled) }
        return await run(claude: DiagnosticClaudeQuota(home: home),
                         codex: DiagnosticCodexQuota(home: home), enabled: enabled)
    }

    static func run(claude claudeProvider: any QuotaProviding = ClaudeQuotaProvider(),
                    codex codexProvider: any QuotaProviding = CodexQuotaProvider(),
                    enabled: Set<ProviderID> = [.claude, .codex]) async -> Int32 {
        async let claude = enabled.contains(.claude) ? query(claudeProvider) : Entry(health: .disabled, snapshot: nil)
        async let codex = enabled.contains(.codex) ? query(codexProvider) : Entry(health: .disabled, snapshot: nil)
        let (claudeEntry, codexEntry) = await (claude, codex)
        let report = Report(generatedAt: Date(), claude: claudeEntry, codex: codexEntry)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print(#"{"error":"额度数据编码失败"}"#)
            return 1
        }
        return report.claude.snapshot == nil && report.codex.snapshot == nil ? 1 : 0
    }

    private static func query(_ provider: any QuotaProviding) async -> Entry {
        do { return Entry(health: .ok, snapshot: try await provider.fetchQuota()) }
        catch {
            let health: ProviderHealth
            switch error as? QuotaError {
            case let .notConfigured(message), let .unauthorized(message): health = .needsSetup(message: message)
            case let .transient(message), let .decoding(message): health = .failed(message: message)
            case nil: health = .failed(message: "额度查询失败")
            }
            return Entry(health: health, snapshot: nil)
        }
    }
}

private struct DiagnosticClaudeQuota: QuotaProviding {
    let agent = ProviderID.claude
    let home: URL
    func fetchQuota() async throws -> QuotaSnapshot {
        let present = await ClaudeCredentialPresence(home: home, useKeychain: false).exists()
        if present == false { throw QuotaError.notConfigured(ClaudeCredentialStore.loginMessage) }
        throw QuotaError.transient("诊断主目录模式仅检查凭据存在性，不查询 Claude 在线额度")
    }
}
private struct DiagnosticCodexQuota: QuotaProviding {
    let agent = ProviderID.codex
    let home: URL
    func fetchQuota() async throws -> QuotaSnapshot {
        try await CodexRolloutQuotaReader(directory: SessionPaths(home: home).codex).fetchQuota()
    }
}
