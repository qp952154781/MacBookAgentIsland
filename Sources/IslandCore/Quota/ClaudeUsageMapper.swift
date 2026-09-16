import Foundation

public enum ClaudeUsageMapper {
    public static func map(data: Data, subscriptionType: String?, rateLimitTier: String?,
                           fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let root = try QuotaJSON.parse(data)
        var windows: [QuotaWindow] = []
        func append(_ value: QuotaJSON, key: String, kind: QuotaWindowKind, label: String,
                    minutes: Int?, percentKey: String = "utilization") {
            guard let percent = value[percentKey].number else { return }
            windows.append(QuotaWindow(id: key, kind: kind, label: label, usedPercent: percent,
                                       windowMinutes: minutes, resetsAt: value["resets_at"].string.flatMap(DateParsing.iso8601)))
        }
        if let limits = root["limits"].array, !limits.isEmpty {
            for value in limits {
                switch value["kind"].string {
                case "session": append(value, key: "limits.session", kind: .session, label: "5 小时", minutes: 300, percentKey: "percent")
                case "weekly_all": append(value, key: "limits.weekly_all", kind: .weekly, label: "本周", minutes: 10080, percentKey: "percent")
                case "weekly_scoped":
                    let name = value["scope"]["model"]["display_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "受限模型"
                    append(value, key: "limits.weekly_scoped.\(name)", kind: .weeklyModel,
                           label: "本周 · \(name)", minutes: 10080, percentKey: "percent")
                default: break
                }
            }
        } else {
            append(root["five_hour"], key: "five_hour", kind: .session, label: "5 小时", minutes: 300)
            append(root["seven_day"], key: "seven_day", kind: .weekly, label: "本周", minutes: 10080)
            append(root["seven_day_opus"], key: "seven_day_opus", kind: .weeklyModel, label: "本周 · Opus", minutes: 10080)
            append(root["seven_day_sonnet"], key: "seven_day_sonnet", kind: .weeklyModel, label: "本周 · Sonnet", minutes: 10080)
            append(root["seven_day_oauth_apps"], key: "seven_day_oauth_apps", kind: .other, label: "本周 · OAuth 应用", minutes: 10080)
        }
        if root["extra_usage"]["is_enabled"].bool == true {
            append(root["extra_usage"], key: "extra_usage", kind: .other, label: "额度包", minutes: nil)
        }
        return QuotaSnapshot(agent: .claude, plan: plan(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier),
                             windows: sortedQuotaWindows(windows), source: .claudeOAuth, fetchedAt: fetchedAt)
    }

    public static func plan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        switch rateLimitTier?.lowercased() {
        case "default_claude_max_5x": return "Max 5x"
        case "default_claude_max_20x": return "Max 20x"
        case "pro", "default_claude_pro": return "Pro"
        default: return subscriptionType.map(quotaCapitalized)
        }
    }
}
