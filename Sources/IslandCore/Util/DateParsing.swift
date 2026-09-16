import Foundation

public enum DateParsing {
    public static func iso8601(_ value: String) -> Date? {
        // Value-type strategies preserve microseconds and avoid shared mutable formatter state.
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(value)
    }

    public static func unixSeconds(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    public static func unixMilliseconds(_ value: Double) -> Date? { unixSeconds(value / 1_000) }
}
