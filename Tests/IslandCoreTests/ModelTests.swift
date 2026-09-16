import Foundation
import Testing
@testable import IslandCore

@Test @MainActor func modelRoundTrips() throws {
    let store = IslandStore.mock(.busy, now: Date(timeIntervalSince1970: 1789182000))
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for quota in store.quotas.values {
        #expect(try decoder.decode(QuotaSnapshot.self, from: encoder.encode(quota)) == quota)
    }
    #expect(try decoder.decode([AgentSession].self, from: encoder.encode(store.sessions)) == store.sessions)
    for health in [ProviderHealth.ok, .stale(lastSuccess: Date(timeIntervalSince1970: 10)),
                   .needsSetup(message: "设置"), .failed(message: "错误"), .disabled] {
        #expect(try decoder.decode(ProviderHealth.self, from: encoder.encode(health)) == health)
    }
    #expect(store.anyWorking)
    #expect(store.workingSessions(for: .claude).count == 1)
    #expect(IslandStore.mock(.idle).sessions.isEmpty)
    #expect(IslandStore.mock(.disconnected).quotas[.claude] == nil)
}

@Test func quotaMath() {
    let now = Date(timeIntervalSince1970: 10000)
    var window = QuotaWindow(id: "test", kind: .session, label: "5 小时", usedPercent: 69.99,
                             windowMinutes: 300, resetsAt: now.addingTimeInterval(9000))
    #expect(window.elapsedFraction(now: now) == 0.5)
    #expect(window.elapsedFraction(now: now.addingTimeInterval(20000)) == 1)
    #expect(window.elapsedFraction(now: now.addingTimeInterval(-20000)) == 0)
    #expect(window.level == .normal)
    window.usedPercent = 70
    #expect(window.level == .warning)
    window.usedPercent = 89.99
    #expect(window.level == .warning)
    window.usedPercent = 90
    #expect(window.level == .critical)
    window.usedPercent = 150
    #expect(window.level == .critical)
    window.windowMinutes = nil
    #expect(window.elapsedFraction(now: now) == nil)
    window.windowMinutes = 0
    #expect(window.elapsedFraction(now: now) == nil)
    var quota = QuotaSnapshot(agent: .claude, windows: [window], source: .mock, fetchedAt: now)
    #expect(quota.headline == window)
    let weekly = QuotaWindow(id: "weekly", kind: .weekly, label: "本周", usedPercent: 20)
    quota.windows.append(weekly)
    #expect(quota.headline == weekly)
    #expect(quota.session == window)
    quota.windows = []
    #expect(quota.headline == nil)
}

@Test func sessionProperties() {
    for phase in SessionPhase.allCases {
        #expect(phase.isWorking == [.thinking, .runningTool, .compacting, .retrying].contains(phase))
        #expect(phase.needsAttention == [.waitingPermission, .error].contains(phase))
        #expect(!phase.label.isEmpty)
    }
    #expect(PlanProgress(completed: 3, total: 7).fraction == 3.0 / 7)
    #expect(PlanProgress(completed: 1, total: 0).fraction == 0)
    #expect(ContextUsage(usedTokens: 335000, windowTokens: 1000000).fraction == 0.335)
    #expect(ContextUsage(usedTokens: 2).fraction == nil)
    #expect(ContextUsage(usedTokens: 2, windowTokens: 0).fraction == nil)
}
