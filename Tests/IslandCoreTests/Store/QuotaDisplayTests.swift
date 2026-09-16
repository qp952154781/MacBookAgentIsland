import Foundation
import Testing
@testable import IslandCore

@Test func remainingPercentClampsAndFloorsWithoutChangingUsage() throws {
    for (used, remaining, text) in [(0.0, 100.0, "100%"), (25.2, 74.8, "74%"),
                                    (100, 0, "0%"), (135, 0, "0%"), (-12, 100, "100%"), (99.9, 0.1, "0%" )] {
        let window = QuotaWindow(id: "fixture", kind: .session, label: "5 小时", usedPercent: used)
        #expect(abs(window.remainingPercent - remaining) < 0.000001)
        #expect(QuotaDisplayMode.remaining.percent(window) == text)
        #expect(QuotaDisplayMode.remaining.percent(window, expanded: true) == "剩 " + text)
        #expect(window.usedPercent == used)
        let encoded = try JSONEncoder().encode(window)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["usedPercent"] as? Double == used)
        #expect(json["remainingPercent"] == nil)
    }
    for value in [Double.nan, .infinity, -.infinity] {
        let window = QuotaWindow(id: "invalid", kind: .other, label: "测试", usedPercent: value)
        for mode in QuotaDisplayMode.allCases {
            #expect(mode.percent(window) == "--")
            #expect(mode.fillFraction(window) == 0)
        }
    }
    #expect(QuotaDisplayMode.remaining.percent(nil) == "--")
}

@Test func remainingAndUsedBarsHaveComplementaryPace() {
    let now = Date(timeIntervalSince1970: 10000)
    var window = QuotaWindow(id: "fixture", kind: .session, label: "5 小时", usedPercent: 30,
                             windowMinutes: 300, resetsAt: now.addingTimeInterval(13500))
    #expect(QuotaDisplayMode.remaining.fillFraction(window) == 0.7)
    #expect(QuotaDisplayMode.used.fillFraction(window) == 0.3)
    #expect(QuotaDisplayMode.remaining.paceFraction(window, now: now) == 0.75)
    #expect(QuotaDisplayMode.used.paceFraction(window, now: now) == 0.25)
    #expect(QuotaDisplayMode.used.percent(window, expanded: true) == "30%")
    for mode in QuotaDisplayMode.allCases {
        #expect(mode.isAheadOfPace(window, now: now))
    }
    window.usedPercent = 25
    for mode in QuotaDisplayMode.allCases { #expect(!mode.isAheadOfPace(window, now: now)) }
    window.usedPercent = 10
    for mode in QuotaDisplayMode.allCases { #expect(!mode.isAheadOfPace(window, now: now)) }
    window.resetsAt = nil
    for mode in QuotaDisplayMode.allCases {
        #expect(mode.paceFraction(window, now: now) == nil)
        #expect(!mode.isAheadOfPace(window, now: now))
    }
}

@MainActor @Test func displayModeHotSwitchRestoresM3AndPreservesQuotaData() throws {
    let settings = AppSettings()
    let store = IslandStore.mock(.idle)
    let original = store.quotas
    #expect(settings.quotaDisplayMode == .remaining)
    #expect(store.quotaDisplayMode == .remaining)
    settings.onChange = { settings.apply(to: store) }
    defer { settings.onChange = nil }
    #expect(store.headline(for: .claude)?.kind == .session)
    #expect(store.quotaDisplayMode.percent(store.headline(for: .claude)) == "82%")
    #expect(store.quotaDisplayMode.percent(store.headline(for: .codex)) == "61%")
    settings.quotaDisplayMode = .used
    #expect(store.quotaDisplayMode == .used)
    #expect(store.headline(for: .claude)?.kind == .weekly)
    #expect(store.quotaDisplayMode.percent(store.headline(for: .claude)) == "62%")
    #expect(store.quotaDisplayMode.percent(store.headline(for: .codex)) == "39%")
    settings.quotaDisplayMode = .remaining
    #expect(store.headline(for: .claude)?.kind == .session)
    #expect(store.quotas == original)
}

@MainActor @Test func missingSessionFallsBackToWeeklyAndCodexToHighestUsage() throws {
    let store = IslandStore.mock(.idle)
    store.quotas[.claude]?.windows.removeAll { $0.kind == .session }
    let claude = try #require(store.quotas[.claude])
    #expect(store.headline(for: .claude)?.kind == .weekly)
    #expect(store.quotaDisplayMode.percent(store.headline(for: .claude)) == "38%")
    #expect(store.quotaDisplayMode.fallbackNote(claude) == "无 5 小时额度，收起态显示本周剩余")
    #expect(QuotaDisplayMode.used.fallbackNote(claude) == nil)
    store.quotas[.claude]?.windows.removeAll { $0.kind == .weekly }
    #expect(store.headline(for: .claude) == nil)
    store.quotas[.codex]?.windows = [
        QuotaWindow(id: "session", kind: .session, label: "5 小时", usedPercent: 15),
        QuotaWindow(id: "other", kind: .other, label: "其他", usedPercent: 75)
    ]
    #expect(store.headline(for: .codex)?.id == "other")
    #expect(store.quotaDisplayMode.percent(store.headline(for: .codex)) == "25%")
    store.quotas[.codex]?.windows = []
    #expect(store.headline(for: .codex) == nil)
}
