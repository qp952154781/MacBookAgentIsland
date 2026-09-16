import Foundation
import Testing
@testable import IslandCore

@Test func codexMappingPrimaryAndTwoWindows() throws {
    let primary = CodexQuotaMapper.map(try GetAccountRateLimitsResponse(data: quotaFixture("codex-primary.json")))
    #expect(primary.plan == "pro")
    #expect(primary.windows.map(\.kind) == [.weekly])
    #expect(primary.windows.map(\.label) == ["本周"])
    #expect(primary.windows.first?.id == "codex.primary")
    #expect(primary.windows.first?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
    let two = CodexQuotaMapper.map(try GetAccountRateLimitsResponse(data: quotaFixture("codex-two.json")))
    #expect(two.windows.map(\.kind) == [.session, .weekly])
    #expect(two.session?.usedPercent == 0)
    #expect(two.session?.resetsAt == nil)
}

@Test func codexMultipleBucketsAndNulls() throws {
    let mapped = CodexQuotaMapper.map(try GetAccountRateLimitsResponse(data: quotaFixture("codex-multiple.json")))
    #expect(mapped.plan == "pro")
    #expect(mapped.windows.map(\.kind) == [.session, .weekly, .weeklyModel, .other, .other])
    #expect(mapped.windows.map(\.label) == ["5 小时 · Variant_a", "本周", "本周 · Variant_a", "24 小时 · Custom", "30 天 · Custom"])
    #expect(mapped.windows.map(\.id) == ["codex_variant_a.primary", "codex.primary", "codex_variant_a.secondary", "codex_named.primary", "codex_named.secondary"])
    let nulls = CodexQuotaMapper.map(try GetAccountRateLimitsResponse(data: quotaFixture("codex-nulls.json")))
    #expect(nulls.plan == nil)
    #expect(nulls.windows.count == 1)
    #expect(nulls.windows.first?.kind == .other)
    #expect(nulls.windows.first?.windowMinutes == nil)
    #expect(nulls.windows.first?.resetsAt == nil)
}

@Test func codexToleranceAndDurationLabels() throws {
    let mapped = CodexQuotaMapper.map(try GetAccountRateLimitsResponse(data: Data(#"{"rateLimits":{"primary":"bad","secondary":{"usedPercent":0,"windowDurationMins":75}},"rateLimitsByLimitId":{"codex_bad":{"primary":{"usedPercent":"bad"}}}}"#.utf8)))
    #expect(mapped.windows.map(\.label) == ["75 分钟"])
    #expect(CodexQuotaMapper.windowType(minutes: 301, extra: false).0 == .session)
    #expect(CodexQuotaMapper.windowType(minutes: 10079, extra: true).0 == .weeklyModel)
}

@Test func claudeStructuredLimitsAndMicroseconds() throws {
    let mapped = try ClaudeUsageMapper.map(data: quotaFixture("claude-limits.json"), subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
    #expect(mapped.plan == "Max 5x")
    #expect(mapped.windows.map(\.label) == ["5 小时", "本周", "本周 · Fable"])
    #expect(mapped.windows.map(\.kind) == [.session, .weekly, .weeklyModel])
    #expect(mapped.windows.map(\.usedPercent) == [14, 17, 21])
    #expect(mapped.windows.map(\.id) == ["limits.session", "limits.weekly_all", "limits.weekly_scoped.Fable"])
    #expect(mapped.windows.map(\.windowMinutes) == [300, 10080, 10080])
    let reset = try #require(mapped.windows.last?.resetsAt)
    let base = try #require(DateParsing.iso8601("2026-09-17T06:00:00Z"))
    #expect(abs(reset.timeIntervalSince(base) - 0.396413) < 0.000002)
}

@Test func claudeLegacyWhitelistPlansAndNulls() throws {
    let full = try ClaudeUsageMapper.map(data: quotaFixture("claude-full.json"), subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    #expect(full.plan == "Max 20x")
    #expect(full.windows.map(\.label) == ["5 小时", "本周", "本周 · Opus", "本周 · Sonnet", "本周 · OAuth 应用", "额度包"])
    #expect(full.windows.last?.windowMinutes == nil)
    let pro = try ClaudeUsageMapper.map(data: quotaFixture("claude-pro.json"), subscriptionType: "pro", rateLimitTier: nil)
    #expect(pro.plan == "Pro")
    #expect(pro.windows.count == 2)
    let unknown = try ClaudeUsageMapper.map(data: quotaFixture("claude-unknown.json"), subscriptionType: "enterprise", rateLimitTier: "unknown")
    #expect(unknown.plan == "Enterprise")
    #expect(unknown.windows.map(\.id) == ["five_hour"])
    #expect(unknown.windows.first?.usedPercent == 0)
    let nulls = try ClaudeUsageMapper.map(data: quotaFixture("claude-nulls.json"), subscriptionType: nil, rateLimitTier: nil)
    #expect(nulls.windows.isEmpty)
    #expect(nulls.plan == nil)
}

@Test func claudeMalformedAndUnknownStructuredWindows() throws {
    let data = Data(#"{"five_hour":{"utilization":99},"limits":[null,{"kind":"session","percent":null},{"kind":"weekly_scoped","percent":12},{"kind":"internal","percent":90}],"extra_usage":{"is_enabled":true,"utilization":0}}"#.utf8)
    let result = try ClaudeUsageMapper.map(data: data, subscriptionType: nil, rateLimitTier: "pro")
    #expect(result.windows.map(\.label) == ["本周 · 受限模型", "额度包"])
    #expect(result.windows.first?.id == "limits.weekly_scoped.受限模型")
    #expect(result.plan == "Pro")
    #expect(throws: QuotaError.decoding("额度响应格式无效")) {
        try ClaudeUsageMapper.map(data: Data("broken".utf8), subscriptionType: nil, rateLimitTier: nil)
    }
}

@Test func rolloutAbsoluteRelativeResetAndBadLines() throws {
    let timestamp = try #require(DateParsing.iso8601("2026-09-11T00:00:00Z"))
    let result = try #require(CodexRolloutQuotaReader.parse(try quotaFixture("rollout.jsonl"), now: timestamp))
    #expect(result.source == .codexRollout)
    #expect(result.fetchedAt == timestamp)
    #expect(result.plan == "pro")
    #expect(result.windows.map(\.kind) == [.session, .weekly])
    #expect(result.session?.resetsAt == timestamp.addingTimeInterval(7200))
    #expect(result.weekly?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
    let expired = try #require(CodexRolloutQuotaReader.parse(try quotaFixture("rollout.jsonl"), now: timestamp.addingTimeInterval(7200)))
    #expect(expired.session?.usedPercent == 0)
    #expect(expired.session?.resetsAt == nil)
    #expect(expired.weekly?.usedPercent == 39)
    #expect(CodexRolloutQuotaReader.parse(Data("bad\n{}\n".utf8), now: timestamp) == nil)
}
