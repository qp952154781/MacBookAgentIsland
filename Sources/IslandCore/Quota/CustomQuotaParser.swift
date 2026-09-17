import Foundation

public struct CustomQuotaResult: Sendable, Equatable {
    public let snapshot: QuotaSnapshot
    public let warnings: [String]
    public init(snapshot: QuotaSnapshot, warnings: [String]) { self.snapshot = snapshot; self.warnings = warnings }
}

public enum CustomQuotaParser {
    public static func parse(_ data: Data, source: CustomSource, now: Date = Date()) throws -> CustomQuotaResult {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            // Foundation's debug description may contain input. Retain only its numeric offset.
            let info = (error as NSError).userInfo
            let debug = info[NSDebugDescriptionErrorKey] as? String ?? ""
            func integer(after marker: String) -> Int? {
                guard let range = debug.range(of: marker) else { return nil }
                return Int(debug[range.upperBound...].prefix(while: { $0.isNumber }))
            }
            if let line = integer(after: "line "), let column = integer(after: "column ") {
                throw CustomSourceError.invalidJSON(line: max(1, line), column: max(1, column))
            }
            var offset = (info["NSJSONSerializationErrorIndex"] as? NSNumber)?.intValue ?? 0
            if let range = debug.range(of: "character ") {
                offset = Int(debug[range.upperBound...].prefix(while: { $0.isNumber })) ?? offset
            }
            let prefix = String(decoding: data.prefix(max(0, offset)), as: UTF8.self)
            let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
            throw CustomSourceError.invalidJSON(line: lines.count, column: (lines.last?.count ?? 0) + 1)
        }
        if let number = number(root) {
            return .init(snapshot: .init(agent: source.id, windows: [
                .init(id: "custom-0", kind: .other, label: source.name, usedPercent: 100 - clamp(number))
            ], source: .customCommand, fetchedAt: now), warnings: [])
        }
        guard let object = root as? [String: Any], let raw = object["windows"] as? [Any], !raw.isEmpty else {
            throw CustomSourceError.emptyWindows
        }
        var warnings: [String] = raw.count > 4 ? ["超过 4 个窗口，仅显示前 4 个"] : []
        var windows: [QuotaWindow] = []
        for (index, value) in raw.prefix(4).enumerated() {
            guard let item = value as? [String: Any] else { throw CustomSourceError.invalidWindow(index + 1) }
            let keys = ["remainingPercent", "usedPercent", "valueText"].filter { item[$0] != nil }
            guard keys.count == 1 else { throw CustomSourceError.invalidWindow(index + 1) }
            var label = (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if label.isEmpty { label = "窗口 \(index + 1)"; warnings.append("窗口 \(index + 1) 缺少 label，已使用默认名称") }
            var used = 0.0
            var text: String?
            if let value = item["valueText"] as? String {
                if value.count > 12 { warnings.append("窗口 \(index + 1) 的 valueText 超过 12 个字符，已截断") }
                text = String(value.prefix(12)).components(separatedBy: .newlines).joined(separator: " ")
            } else if let remaining = item["remainingPercent"].flatMap(number) { used = 100 - clamp(remaining) }
            else if let percent = item["usedPercent"].flatMap(number) { used = clamp(percent) }
            else { throw CustomSourceError.invalidWindow(index + 1) }
            var reset: Date?
            if let value = item["resetsAt"] as? String {
                let formatter = ISO8601DateFormatter()
                reset = formatter.date(from: value)
                if reset == nil { formatter.formatOptions.insert(.withFractionalSeconds); reset = formatter.date(from: value) }
                if reset == nil { warnings.append("窗口 \(index + 1) 的 resetsAt 无效，已忽略") }
            }
            let period = item["periodSeconds"].flatMap(number).flatMap { $0 > 0 ? $0 : nil }
            windows.append(.init(id: "custom-\(index)", kind: .other, label: label, usedPercent: used,
                                 resetsAt: reset, valueText: text, periodSeconds: period))
        }
        return .init(snapshot: .init(agent: source.id, plan: object["plan"] as? String, windows: windows,
                                    source: .customCommand, fetchedAt: now,
                                    note: (object["note"] as? String)?.components(separatedBy: .newlines).joined(separator: " ")),
                     warnings: warnings)
    }
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func clamp(_ value: Double) -> Double { min(100, max(0, value)) }
}
