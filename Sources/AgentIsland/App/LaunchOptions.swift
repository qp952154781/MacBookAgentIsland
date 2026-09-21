import Foundation
import IslandCore

struct LaunchOptions {
    enum LoginItemAction: String, Sendable, CaseIterable {
        case on, off, status
    }

    var help = false
    var home: URL?
    var processStarted = ContinuousClock.now
    var printGeometry = false
    var measure = false
    var snapshotDirectory: String?
    var snapshotAnimationDirectory: String?
    var mockScenario: MockScenario?
    var forcedState: IslandMode?
    var cycleStates: TimeInterval?
    var exitAfter: TimeInterval?
    var dump: String?
    var loginItem: LoginItemAction?

    static let helpText = """
    AgentIsland
      --dump providers|quota|sessions|system|claude-log  导出诊断数据后退出
      --home <目录>  仅供 --dump 诊断使用；GUI 模式不接受
        凭据仅检查该目录的 .claude/.credentials.json 是否存在，跳过钥匙串。
        安装检测仅查此目录的 .claude/、.codex/ 是否存在，忽略可执行文件及本机用户设置。
        providers 将最后观察到的 Claude 模型名保存在此目录的应用偏好文件中；无记录时只尾读近 30 天最新 transcript。
        quota 仅导出此目录中的 Codex 本地额度，不读取令牌或启动在线查询、续期器。
      --snapshot <目录>  使用 Metal 生成快照后退出
      --snapshot-animation <目录>  使用 Metal 生成 README 演示动图后退出
      --mock idle|busy|critical|disconnected|no-credentials  使用模拟数据
        disconnected：有凭据、连接恢复中；no-credentials：无凭据、显示登录指引。
      --force-state collapsed|active|expanded  固定显示状态
      --cycle-states <秒>  在收起与展开之间循环切换（动画验收用）
      --exit-after <秒>  限时退出
      --print-geometry  打印屏幕几何
      --measure  限时测量
      --login-item on|off|status  管理开机启动
      --help  显示帮助
    """

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
            case "--help", "-h": help = true
            case "--home":
                guard home == nil else { throw ParseError.invalid("--home 不能重复使用") }
                let path = try value(after: flag)
                guard !path.isEmpty else { throw ParseError.invalid("--home 目录不能为空") }
                home = SessionPaths(home: URL(fileURLWithPath: path, isDirectory: true)).home
            case "--measure": measure = true
            case "--print-geometry": printGeometry = true
            case "--snapshot": snapshotDirectory = try value(after: flag)
            case "--snapshot-animation": snapshotAnimationDirectory = try value(after: flag)
            case "--mock":
                guard let scenario = MockScenario(rawValue: try value(after: flag)) else { throw ParseError.invalid("无效的 mock 场景") }
                mockScenario = scenario
            case "--force-state":
                guard let state = IslandMode(rawValue: try value(after: flag)) else { throw ParseError.invalid("无效的岛状态") }
                forcedState = state
            case "--cycle-states":
                guard let seconds = Double(try value(after: flag)), seconds.isFinite, (0.3...30).contains(seconds) else {
                    throw ParseError.invalid("循环间隔必须在 0.3 到 30 秒之间")
                }
                cycleStates = seconds
            case "--exit-after":
                guard let seconds = Double(try value(after: flag)), seconds.isFinite, seconds >= 0 else {
                    throw ParseError.invalid("退出时间必须为非负秒数")
                }
                exitAfter = seconds
            case "--dump":
                let target = try value(after: flag)
                guard ["quota", "sessions", "system", "claude-log", "providers"].contains(target) else { throw ParseError.invalid("--dump 只支持 quota、sessions、system、claude-log 或 providers") }
                dump = target
            default: throw ParseError.invalid("未知参数：\(flag)")
            }
            index += 1
        }
        if cycleStates != nil, forcedState != nil { throw ParseError.invalid("--cycle-states 不能与 --force-state 同时使用") }
        if home != nil, dump == nil { throw ParseError.invalid("--home 仅供 --dump 诊断使用，GUI 模式不接受此参数") }
        let auditModes = [printGeometry, snapshotDirectory != nil, snapshotAnimationDirectory != nil,
                          dump != nil, measure].filter { $0 }.count
        guard auditModes <= 1 else { throw ParseError.invalid("几何、快照、动图、测量与数据导出模式不能同时使用") }
        if loginItem != nil {
            guard auditModes == 0, mockScenario == nil, forcedState == nil, cycleStates == nil else {
                throw ParseError.invalid("--login-item 不能与其它运行模式同时使用")
            }
        }
    }
}
