import Foundation

public enum SystemTopBandFormat {
    private static let units = ["K", "M", "G", "T", "P", "E", "Z", "Y"]
    public static let percentagePrototypes = ["100%", "—"]
    // FanReader accepts UInt32 RPM values. Reserve the entire supported range, including stop text.
    public static let fanPrototypes = ["0000000000", "静止"]

    public static func ratePrototypes(compact: Bool) -> [String] {
        compact ? units.flatMap { ["1023" + $0, "9.9" + $0] } + ["9e308B", "—"]
            : units.map { "1024.0 " + $0 + "B/s" } + ["9e308 B/s", "—"]
    }

    /// Bound every finite rate's text width, including synthetic or malformed extreme counters.
    public static func rate(_ bytes: Double?, compact: Bool) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        guard bytes >= 1024 else { return compact ? "0K" : "0 KB/s" }
        var value = bytes / 1024, index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        if value >= 1024 { return scientific(bytes, compact: compact) }
        if compact, value.rounded() >= 1024 {
            if index < units.count - 1 { value /= 1024; index += 1 }
            else { return scientific(bytes, compact: true) }
        }
        let format = compact ? (value < 10 ? "%.1f" : "%.0f") : "%.1f"
        let number = String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
        return number + (compact ? units[index] : " " + units[index] + "B/s")
    }

    private static func scientific(_ bytes: Double, compact: Bool) -> String {
        let number = String(format: "%.0e", locale: Locale(identifier: "en_US_POSIX"), bytes)
            .lowercased().replacingOccurrences(of: "e+", with: "e")
        return number + (compact ? "B" : " B/s")
    }
}
