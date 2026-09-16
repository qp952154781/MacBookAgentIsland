import Foundation

/// A bounded line screen. Decoder state survives arbitrary ANSI and UTF-8 chunk boundaries.
struct ClaudeTerminalParser: Sendable {
    private enum Escape: Sendable { case none, start, intermediate, csi, osc, oscEnd }
    private var escape = Escape.none
    private var parameters: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Length = 0
    private var lines: [[Unicode.Scalar]] = [[]]
    private var row = 0
    private var column = 0
    private static let rowLimit = 256
    private static let columnLimit = 512
    private(set) var terminalResult: ClaudeRefreshResult?
    private var detectsSetup = true

    mutating func beginUsage() { detectsSetup = false }

    static let setupRules = ["let's get started", "choose the text style", "do you trust", "trust the files",
        "select login method", "/login", "press enter to continue", "select a theme", "choose a theme",
        "security guide", "allow this", "do you want to proceed", "would you like to", "permission",
        "enter to confirm", "enter to select", "yes, i trust", "sign in", "log in", "login required",
        "quick safety check", "yes, i trust this folder", "no, exit", "esc to cancel",
        "chrome extension detected", "keep browser tools off", "use my browser"]
    private static let loginRules = ["oauth session expired and could not be refreshed", "refresh token expired", "invalid refresh token", "refresh token is invalid", "refresh token has expired"]
    private static let compactSetupRules = setupRules.map(compact)
    private static let compactLoginRules = loginRules.map(compact)
    private static let ruleContextLength = (compactSetupRules + compactLoginRules).map(\.count).max() ?? 0
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    var text: String { lines.map { String(String.UnicodeScalarView($0)) }.joined(separator: "\n").lowercased() }
    var isComplete: Bool { escape == .none && utf8.isEmpty }
    var isReady: Bool { terminalResult == nil && isComplete && Self.hasPrompt(text) }

    @discardableResult
    mutating func consume(_ data: Data) -> String {
        for byte in data {
            switch escape {
            case .start:
                parameters.removeAll(keepingCapacity: true)
                if byte == 91 { escape = .csi }
                else if byte == 93 { escape = .osc }
                else if (32...47).contains(byte) { escape = .intermediate }
                else { escape = .none }
            case .intermediate:
                if (48...126).contains(byte) { escape = .none }
            case .csi:
                if (64...126).contains(byte) { applyCSI(byte); escape = .none }
                else if parameters.count < 64 { parameters.append(byte) }
                else { failClosed() }
            case .osc:
                if byte == 7 { escape = .none }
                else if byte == 27 { escape = .oscEnd }
            case .oscEnd:
                if byte == 92 || byte == 7 { escape = .none }
                else if byte != 27 { escape = .osc }
            case .none:
                consumeText(byte)
            }
        }
        latch(Self.result(text, detectsSetup: detectsSetup))
        return text
    }

    private mutating func consumeText(_ byte: UInt8) {
        if !utf8.isEmpty {
            if (128...191).contains(byte) {
                utf8.append(byte)
                if utf8.count == utf8Length {
                    for scalar in String(decoding: utf8, as: UTF8.self).unicodeScalars { put(scalar) }
                    utf8.removeAll(keepingCapacity: true)
                }
                return
            }
            put("\u{fffd}"); utf8.removeAll(keepingCapacity: true)
        }
        switch byte {
        case 27: escape = .start
        case 13: column = 0
        case 10:
            // PTY output uses newline mode; fixtures also contain normalized LF line endings.
            latch(Self.result(text, detectsSetup: detectsSetup)); move(row: row + 1, column: 0)
        case 9: move(row: row, column: (column / 8 + 1) * 8)
        case 8: column = max(0, column - 1)
        case 32...126: put(Unicode.Scalar(byte))
        case 194...244:
            utf8 = [byte]; utf8Length = byte < 224 ? 2 : byte < 240 ? 3 : 4
        case 128...255: put("\u{fffd}")
        default: break
        }
    }
    private mutating func put(_ scalar: Unicode.Scalar) {
        guard column < Self.columnLimit else { failClosed(); return }
        if lines[row].count <= column {
            lines[row].append(contentsOf: repeatElement(" ", count: column + 1 - lines[row].count))
        }
        lines[row][column] = scalar; column += 1
        // Latch before a later redraw can erase a dangerous dialog, even within one read.
        if case .needsUserSetup = terminalResult { return }
        latch(Self.result(ruleContext(), detectsSetup: detectsSetup))
    }
    private func ruleContext() -> String {
        // Include neighboring text so a phrase split over rows is latched before an erase,
        // independently of whether the caller ended a chunk between those operations.
        let limit = Self.ruleContextLength
        var before = "", after = ""
        for index in (0..<row).reversed() {
            before = String((Self.compact(String(String.UnicodeScalarView(lines[index]))) + before).suffix(limit))
            if before.count >= limit { break }
        }
        if row + 1 < lines.count {
            for index in (row + 1)..<lines.count {
                after = String((after + Self.compact(String(String.UnicodeScalarView(lines[index])))).prefix(limit))
                if after.count >= limit { break }
            }
        }
        return before + String(String.UnicodeScalarView(lines[row])) + after
    }
    private mutating func move(row: Int, column: Int) {
        guard row < Self.rowLimit, column < Self.columnLimit else { failClosed(); return }
        self.row = max(0, row); self.column = max(0, column)
        while lines.count <= self.row { lines.append([]) }
        if lines[self.row].count < self.column {
            lines[self.row].append(contentsOf: repeatElement(" ", count: self.column - lines[self.row].count))
        }
    }
    private mutating func applyCSI(_ final: UInt8) {
        // Ignore private modes, SGR, queries and unsupported intermediates without emitting text.
        guard parameters.allSatisfy({ (48...57).contains($0) || $0 == 59 }) else { return }
        let values = String(decoding: parameters, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        func value(_ index: Int, default fallback: Int) -> Int {
            guard index < values.count, !values[index].isEmpty else { return fallback }
            return Int(values[index]) ?? Int.max
        }
        let amount = max(1, value(0, default: 1))
        switch final {
        case 71: move(row: row, column: amount - 1) // CHA
        case 67: move(row: row, column: column + min(amount, Self.columnLimit)) // CUF
        case 68: move(row: row, column: max(0, column - amount)) // CUB
        case 65: move(row: max(0, row - amount), column: column) // CUU
        case 66: move(row: row + min(amount, Self.rowLimit), column: column) // CUD
        case 72: move(row: amount - 1, column: max(1, value(1, default: 1)) - 1) // CUP
        case 75:
            eraseLine(value(0, default: 0)); latch(Self.result(text, detectsSetup: detectsSetup))
        case 74:
            let mode = value(0, default: 0)
            if mode == 2 { lines = Array(repeating: [], count: row + 1) }
            else if mode == 0 {
                eraseLine(0)
                if row + 1 < lines.count { lines.removeSubrange((row + 1)..<lines.count) }
            } else if mode == 1 {
                for index in 0..<row { lines[index] = [] }
                eraseLine(1)
            }
            latch(Self.result(text, detectsSetup: detectsSetup))
        default: break
        }
    }
    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 0: if column < lines[row].count { lines[row].removeSubrange(column..<lines[row].count) }
        case 1:
            for index in 0..<min(column + 1, lines[row].count) { lines[row][index] = " " }
        case 2: lines[row] = []
        default: break
        }
    }
    private mutating func failClosed() { latch(.failed("续期终端输出超出解析范围")) }
    private mutating func latch(_ result: ClaudeRefreshResult?) {
        guard let result else { return }
        if case .needsUserSetup = result { terminalResult = result }
        else if terminalResult == nil { terminalResult = result }
    }
    static func result(_ text: String, detectsSetup: Bool = true) -> ClaudeRefreshResult? {
        let original = text.lowercased(), condensed = compact(original)
        if detectsSetup && (setupRules.contains(where: original.contains) || compactSetupRules.contains(where: condensed.contains)) {
            return .needsUserSetup("需要在终端完成一次 Claude Code 首次设置")
        }
        if loginRules.contains(where: original.contains) || compactLoginRules.contains(where: condensed.contains) {
            return .needsLogin
        }
        return nil
    }
    static func hasPrompt(_ text: String) -> Bool {
        guard result(text) == nil else { return false }
        let lines = text.components(separatedBy: "\n")
        let separator = String(repeating: "─", count: 20)
        return lines.indices.contains { index in
            lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("❯") &&
                lines[..<index].contains(where: { $0.contains(separator) }) &&
                lines[(index + 1)...].contains(where: { $0.contains(separator) })
        }
    }
}

/// Only the serialized interaction loop owns this gate and writes to the PTY.
/// A terminal result permanently closes it, including after subsequent screen clears.
struct ClaudePTYWriteGate: Sendable {
    private var parser = ClaudeTerminalParser()
    private(set) var hasOpened = false
    private(set) var usageSent = false
    var result: ClaudeRefreshResult? { parser.terminalResult }
    var isOpen: Bool { !usageSent && parser.isReady }
    mutating func consume(_ data: Data) {
        parser.consume(data)
    }
    mutating func beginUsage() -> Bool {
        guard !usageSent, isOpen else { return false }
        hasOpened = true; usageSent = true
        parser.beginUsage()
        return true
    }
}
