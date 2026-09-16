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

    static func run(claude claudeProvider: any QuotaProviding = ClaudeQuotaProvider(),
                    codex codexProvider: any QuotaProviding = CodexQuotaProvider()) async -> Int32 {
        async let claude = query(claudeProvider)
        async let codex = query(codexProvider)
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
