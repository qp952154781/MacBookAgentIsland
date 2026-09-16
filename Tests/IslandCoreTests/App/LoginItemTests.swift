import Foundation
import ServiceManagement
import Testing
@testable import AgentIsland

@Test(arguments: LaunchOptions.LoginItemAction.allCases)
func loginItemParsesActions(_ action: LaunchOptions.LoginItemAction) throws {
    let options = try LaunchOptions(arguments: ["--login-item", action.rawValue])
    #expect(options.loginItem == action)
}

@Test(arguments: [
    ["--login-item"],
    ["--login-item", "invalid"],
    ["--login-item", "ON"],
    ["--login-item", "on", "--login-item", "off"]
])
func loginItemRejectsInvalidArguments(_ arguments: [String]) {
    #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions(arguments: arguments) }
}

@Test(arguments: [
    ["--snapshot", "fixture-snapshots"],
    ["--dump", "quota"],
    ["--dump", "sessions"],
    ["--print-geometry"],
    ["--measure"],
    ["--mock", "idle"],
    ["--force-state", "collapsed"]
])
func loginItemRejectsOtherModes(_ mode: [String]) throws {
    // Ensure rejection comes from mutual exclusion, not an invalid fixture mode.
    _ = try LaunchOptions(arguments: mode)
    for action in LaunchOptions.LoginItemAction.allCases {
        let login = ["--login-item", action.rawValue]
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions(arguments: login + mode) }
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions(arguments: mode + login) }
    }
}

@Test func loginItemAllowsExitDeadline() throws {
    let options = try LaunchOptions(arguments: ["--login-item", "status", "--exit-after", "2"])
    #expect(options.loginItem == .status && options.exitAfter == 2)
}

@Test func loginItemReportsSystemStateAndApprovalEvenAfterFailure() throws {
    let states: [(SMAppService.Status, String, Bool)] = [
        (.enabled, "enabled", true), (.requiresApproval, "requiresApproval", true),
        (.notRegistered, "notRegistered", false), (.notFound, "notFound", false)
    ]
    for (status, name, registered) in states {
        let report = LoginItemCommand.Report(status: status, bundlePath: "/Applications/AgentIsland.app")
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["status", "registered", "bundlePath", "message"])
        #expect(json["status"] as? String == name)
        #expect(json["registered"] as? Bool == registered)
        #expect(json["bundlePath"] as? String == "/Applications/AgentIsland.app")
        #expect(!report.message.isEmpty)
    }
    let approval = LoginItemCommand.Report(status: .requiresApproval, bundlePath: "fixture.app", failure: "测试错误")
    #expect(approval.registered)
    #expect(approval.message.contains("测试错误"))
    #expect(approval.message.contains("请在 系统设置 → 通用 → 登录项与扩展 中允许 AgentIsland"))
    let missing = LoginItemCommand.Report(status: .notFound, bundlePath: ".build/debug")
    #expect(missing.message.contains("请从 /Applications/AgentIsland.app 内的可执行文件运行"))
    #expect(!LoginItemCommand.isApplicationBundle(.main))
}
