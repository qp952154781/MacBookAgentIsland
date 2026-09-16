import Foundation

// A tolerant, Sendable tree keeps malformed optional fields local to their window.
indirect enum QuotaJSON: Decodable, Sendable {
    case object([String: QuotaJSON]), array([QuotaJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([String: QuotaJSON].self) { self = .object(v) }
        else { self = .array(try value.decode([QuotaJSON].self)) }
    }
    subscript(_ key: String) -> QuotaJSON { object?[key] ?? .null }
    var object: [String: QuotaJSON]? { if case let .object(v) = self { v } else { nil } }
    var array: [QuotaJSON]? { if case let .array(v) = self { v } else { nil } }
    var string: String? { if case let .string(v) = self { v } else { nil } }
    var number: Double? { if case let .number(v) = self, v.isFinite { v } else { nil } }
    var integer: Int? { number.flatMap(Int.init(exactly:)) }
    var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    static func parse(_ data: Data) throws -> QuotaJSON {
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.object != nil else { throw QuotaError.decoding("额度响应格式无效") }
            return value
        } catch { throw QuotaError.decoding("额度响应格式无效") }
    }
}

func sortedQuotaWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
    func rank(_ kind: QuotaWindowKind) -> Int {
        switch kind { case .session: 0; case .weekly: 1; case .weeklyModel: 2; case .other: 3 }
    }
    return windows.enumerated().sorted {
        let a = rank($0.element.kind), b = rank($1.element.kind)
        return a == b ? $0.offset < $1.offset : a < b
    }.map(\.element)
}

func quotaCapitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

public extension QuotaError {
    var message: String {
        switch self {
        case let .notConfigured(v), let .unauthorized(v), let .transient(v), let .decoding(v): v
        }
    }
}
