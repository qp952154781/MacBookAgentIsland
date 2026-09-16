import Foundation
import IslandCore

struct LaunchOptions {
    enum LoginItemAction: String, Sendable, CaseIterable {
        case on, off, status
    }

    var processStarted = ContinuousClock.now
    var printGeometry = false
    var measure = false
    var snapshotDirectory: String?
    var mockScenario: MockScenario?
    var forcedState: IslandMode?
    var exitAfter: TimeInterval?
    var dump: String?
    var loginItem: LoginItemAction?

    enum ParseError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case let .invalid(message): message } }
    }

    init(arguments: [String]) throws {
        var index = 0
        func value(after flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.invalid("\(flag) 缺少参数") }
            return arguments[index]
        }
        while index < arguments.count {
            let flag = arguments[index]
            switch flag {
            case "--login-item":
                guard loginItem == nil else { throw ParseError.invalid("--login-item 不能重复使用") }
                guard let action = LoginItemAction(rawValue: try value(after: flag)) else {
                    throw ParseError.invalid("--login-item 只支持 on、off 或 status")
                }
                loginItem = action
            case "--measure": measure = true
            case "--print-geometry": printGeometry = true
            case "--snapshot": snapshotDirectory = try value(after: flag)
            case "--mock":
                guard let scenario = MockScenario(rawValue: try value(after: flag)) else { throw ParseError.invalid("无效的 mock 场景") }
                mockScenario = scenario
            case "--force-state":
                guard let state = IslandMode(rawValue: try value(after: flag)) else { throw ParseError.invalid("无效的岛状态") }
                forcedState = state
            case "--exit-after":
                guard let seconds = Double(try value(after: flag)), seconds.isFinite, seconds >= 0 else {
                    throw ParseError.invalid("退出时间必须为非负秒数")
                }
                exitAfter = seconds
            case "--dump":
                let target = try value(after: flag)
                guard ["quota", "sessions", "system", "claude-log"].contains(target) else { throw ParseError.invalid("--dump 只支持 quota、sessions、system 或 claude-log") }
                dump = target
            default: throw ParseError.invalid("未知参数：\(flag)")
            }
            index += 1
        }
        let auditModes = [printGeometry, snapshotDirectory != nil, dump != nil, measure].filter { $0 }.count
        guard auditModes <= 1 else { throw ParseError.invalid("几何、快照、测量与数据导出模式不能同时使用") }
        if loginItem != nil {
            guard auditModes == 0, mockScenario == nil, forcedState == nil else {
                throw ParseError.invalid("--login-item 不能与其它运行模式同时使用")
            }
        }
    }
}
