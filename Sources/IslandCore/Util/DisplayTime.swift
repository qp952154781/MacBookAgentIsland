import Foundation

public enum DisplayTime {
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--" }
        let minutes = Int(min(Double(Int.max / 60), max(0, seconds)) / 60)
        if minutes == 0 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 1440 { return "\(minutes / 60)小时\(minutes % 60)分" }
        return "\(minutes / 1440)天\(minutes % 1440 / 60)小时"
    }
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "HH:mm", timeZone: timeZone)
    }
    public static func full(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "yyyy-MM-dd HH:mm", timeZone: timeZone)
    }
    public static func reset(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "--" }
        let seconds = date.timeIntervalSince(now)
        guard seconds.isFinite, abs(date.timeIntervalSince1970) < 253_402_300_800 else { return "时间异常" }
        if seconds <= 0 { return "—" }
        if seconds < 86400 {
            let minutes = Int(seconds / 60)
            return minutes == 0 ? "<1m" : "\(minutes / 60)h\(minutes % 60)m"
        }
        return format(date, pattern: "EE HH:mm", timeZone: timeZone)
    }
    public static func resetHelp(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "服务端未提供重置时间" }
        if date <= now { return "服务端未提供新的重置时间" }
        return "重置于 " + full(date, timeZone: timeZone)
    }
    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 253_402_300_800 else { return "时间异常" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

public extension QuotaSource {
    var label: String {
        switch self {
        case .codexAppServer: "Codex 本地服务"
        case .codexRollout: "Codex 会话记录"
        case .claudeOAuth: "Claude 额度接口"
        case .claudeStatusLine: "Claude 状态行"
        case .mock: "演示数据"
        }
    }
}
