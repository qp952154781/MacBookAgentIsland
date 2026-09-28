import Foundation
import Testing
@testable import IslandCore
@testable import AgentIsland

@Test func codexDumpMarksRolloutFallbackStaleAndExplainsMissingExecutable() async throws {
    var snapshot = quotaSample(.codex)
    snapshot.source = .codexRollout
    snapshot.note = "来自 Codex 会话记录 · 09:28"
    let rollout = SequenceQuotaProvider(agent: .codex, [.success(snapshot)])
    let provider = CodexQuotaProvider(appServer: { throw QuotaError.notConfigured("未找到 Codex") }, rollout: rollout)
    let entry = await DumpQuota.query(provider)
    #expect(entry.health == .stale(lastSuccess: snapshot.fetchedAt))
    #expect(entry.snapshot?.note == snapshot.note)
    let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
    #expect(encoded.contains("未找到 Codex 程序，已退回会话记录"))
}
