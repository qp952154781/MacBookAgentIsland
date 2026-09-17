import Foundation

public enum SystemTopBandFormat {
    /// Network rates are shown up to terabytes per second; anything larger is treated as a bogus counter.
    private static let units = ["K", "M", "G", "T"]
    public static let percentagePrototypes = ["100%", "—"]
    /// Real Mac fans stay well below 100,000 RPM. Larger readings are shown as "—" rather than
    /// reserving width for the full UInt32 range on every layout pass.
    public static let maximumFanRPM = 99_999.0
    public static let fanPrototypes = ["99999", "静止", "—"]

    /// The widest strings `rate(_:compact:)` can produce, measured once to reserve slot widths.
    public static func ratePrototypes(compact: Bool) -> [String] {
        compact ? units.flatMap { ["999" + $0, "9.9" + $0] } + ["0K", "—"]
            : units.map { "999.9 " + $0 + "B/s" } + ["0 KB/s", "—"]
    }

    /// Compact rates use at most three significant characters ("9.9K", "999K", "1.0M");
    /// full rates use one decimal ("999.9 KB/s"). Values that round to 1000 roll over to the next unit.
    public static func rate(_ bytes: Double?, compact: Bool) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        guard bytes >= 1024 else { return compact ? "0K" : "0 KB/s" }
        var value = bytes / 1024, index = 0
        // Full format rounds to 0.1, compact to whole numbers from 10 upward.
        let rollover = compact ? 999.5 : 999.95
        while value >= rollover {
            guard index < units.count - 1 else { return "—" }
            value /= 1024; index += 1
        }
        let format = compact ? (value < 9.95 ? "%.1f" : "%.0f") : "%.1f"
        let number = String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
        return number + (compact ? units[index] : " " + units[index] + "B/s")
    }

    public static func fan(_ rpm: Double?) -> String {
        guard let rpm, rpm.isFinite, rpm >= 0 else { return "—" }
        if rpm == 0 { return "静止" }
        guard rpm.rounded() <= maximumFanRPM else { return "—" }
        return String(Int(rpm.rounded()))
    }
}
