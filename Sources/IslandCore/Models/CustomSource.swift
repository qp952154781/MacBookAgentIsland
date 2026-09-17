import Foundation

public struct CustomSource: Codable, Equatable, Sendable, Identifiable {
    public var id: ProviderID
    public var name: String
    public var command: String
    public var intervalMinutes: Int
    public var applicationPath: String?
    public var colorIndex: Int
    public static let intervals = [1, 5, 15, 30]
    public static let palette: [ProviderDescriptor.RGB] = [
        .init(red: 0.38, green: 0.80, blue: 0.62), .init(red: 0.76, green: 0.56, blue: 0.94),
        .init(red: 0.93, green: 0.69, blue: 0.30), .init(red: 0.94, green: 0.49, blue: 0.69)
    ]
    public init(id: ProviderID = .init(rawValue: "custom-" + UUID().uuidString.lowercased()),
                name: String = "", command: String = "", intervalMinutes: Int = 5,
                applicationPath: String? = nil, colorIndex: Int = 0) {
        self.id = id; self.name = name; self.command = command
        self.intervalMinutes = Self.intervals.contains(intervalMinutes) ? intervalMinutes : 5
        self.applicationPath = applicationPath; self.colorIndex = colorIndex
    }
    public var isValid: Bool {
        id.rawValue.hasPrefix("custom-") && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !command.contains("\0")
    }
    public var interval: TimeInterval { Double(Self.intervals.contains(intervalMinutes) ? intervalMinutes : 5) * 60 }
    public var descriptor: ProviderDescriptor {
        .init(id: id, displayName: name, brandColor: Self.palette[max(0, colorIndex) % Self.palette.count],
              iconSource: applicationPath.map { .applicationPath($0) } ?? .none, hasQuota: true, hasSessions: false)
    }
}

public enum ProviderOrder {
    public static func arrange(_ declarations: [ProviderDescriptor], order: [ProviderID]) -> [ProviderDescriptor] {
        var seen = Set<ProviderID>()
        return (order.compactMap { id in declarations.first { $0.id == id } } + declarations)
            .filter { seen.insert($0.id).inserted }
    }
}

public struct CustomRunStatus: Sendable, Equatable, Encodable {
    public let time: Date
    public let category: String
    public init(time: Date, category: String) { self.time = time; self.category = category }
}

public enum CustomSourceError: Error, Sendable, Equatable {
    case launch, timeout, outputTooLarge, exit(Int32, String), invalidJSON(line: Int, column: Int), invalidWindow(Int), emptyWindows
    public var category: String {
        switch self {
        case .launch: "launch"
        case .timeout: "timeout"
        case .outputTooLarge: "outputTooLarge"
        case .exit(let code, _): code == 127 ? "commandNotFound" : "exit"
        case .invalidJSON, .invalidWindow, .emptyWindows: "invalidJSON"
        }
    }
    public var message: String {
        switch self {
        case .launch: "无法启动命令"
        case .timeout: "命令超时"
        case .outputTooLarge: "输出过大（上限 64 KB）"
        case .exit(let code, let summary): (code == 127 ? "命令未找到" : "命令执行失败") + "（退出码 \(code)）" + (summary.isEmpty ? "" : "：" + summary)
        case .invalidJSON(let line, let column): "JSON 格式错误（第 \(line) 行，第 \(column) 列）"
        case .invalidWindow(let index): "窗口 \(index) 必须且只能提供 remainingPercent、usedPercent、valueText 中的一项有效值"
        case .emptyWindows: "windows 必须包含 1–4 个窗口"
        }
    }
}
