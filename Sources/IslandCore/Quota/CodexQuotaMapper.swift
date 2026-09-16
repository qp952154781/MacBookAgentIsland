import Foundation

public struct GetAccountRateLimitsResponse: Decodable, Sendable {
    let value: QuotaJSON
    public init(from decoder: any Decoder) throws { value = try QuotaJSON(from: decoder) }
    public init(data: Data) throws { value = try QuotaJSON.parse(data) }
}

public enum CodexQuotaMapper {
    public static func map(_ response: GetAccountRateLimitsResponse, fetchedAt: Date = Date()) -> QuotaSnapshot {
        let buckets = response.value["rateLimitsByLimitId"].object ?? [:]
        let main = buckets["codex"].flatMap { $0.object == nil ? nil : $0 } ?? response.value["rateLimits"]
        var windows = bucketWindows(main, id: "codex", extra: false)
        for id in buckets.keys.sorted() where id != "codex" {
            if let bucket = buckets[id] { windows += bucketWindows(bucket, id: id, extra: true) }
        }
        return QuotaSnapshot(agent: .codex, plan: main["planType"].string,
                             windows: sortedQuotaWindows(windows), source: .codexAppServer, fetchedAt: fetchedAt)
    }

    static func bucketWindows(_ bucket: QuotaJSON, id: String, extra: Bool) -> [QuotaWindow] {
        let fallback = id.hasPrefix("codex_") ? String(id.dropFirst(6)) : id
        let name = bucket["limitName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? quotaCapitalized(fallback)
        return ["primary", "secondary"].compactMap { slot in
            let value = bucket[slot]
            guard let used = value["usedPercent"].number, !extra || used != 0 else { return nil }
            let minutes = value["windowDurationMins"].integer
            let (kind, label) = windowType(minutes: minutes, extra: extra)
            return QuotaWindow(id: "\(id).\(slot)", kind: kind,
                               label: label + (extra ? " · \(name)" : ""), usedPercent: used,
                               windowMinutes: minutes, resetsAt: value["resetsAt"].number.flatMap(DateParsing.unixSeconds))
        }
    }

    static func windowType(minutes: Int?, extra: Bool) -> (QuotaWindowKind, String) {
        // Allow small server rounding differences without classifying unrelated durations.
        if let minutes, (295...305).contains(minutes) { return (.session, "5 小时") }
        if let minutes, (10075...10085).contains(minutes) { return (extra ? .weeklyModel : .weekly, "本周") }
        guard let minutes, minutes > 0 else { return (.other, "其他额度") }
        if minutes > 1440, minutes % 1440 == 0 { return (.other, "\(minutes / 1440) 天") }
        if minutes % 60 == 0 { return (.other, "\(minutes / 60) 小时") }
        return (.other, "\(minutes) 分钟")
    }
}
