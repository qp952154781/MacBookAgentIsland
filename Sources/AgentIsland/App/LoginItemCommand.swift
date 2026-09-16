import Foundation
import Dispatch
import ServiceManagement
import IslandCore

enum LoginItemCommand {
    struct Report: Encodable, Sendable {
        let status: String
        let registered: Bool
        let bundlePath: String
        let message: String

        init(status: SMAppService.Status, bundlePath: String, failure: String? = nil) {
            self.bundlePath = bundlePath
            registered = status == .enabled || status == .requiresApproval
            let explanation: String
            switch status {
            case .enabled:
                self.status = "enabled"
                explanation = "开机启动已开启。"
            case .requiresApproval:
                self.status = "requiresApproval"
                explanation = "请在 系统设置 → 通用 → 登录项与扩展 中允许 AgentIsland"
            case .notRegistered:
                self.status = "notRegistered"
                explanation = "开机启动未注册。"
            case .notFound:
                self.status = "notFound"
                explanation = "未找到有效的登录项；请从 /Applications/AgentIsland.app 内的可执行文件运行"
            @unknown default:
                self.status = "notFound"
                explanation = "无法识别登录项状态，请检查系统登录项设置。"
            }
            message = failure.map { "开机启动操作失败：\($0)。\(explanation)" } ?? explanation
        }
    }

    static func isApplicationBundle(_ bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              bundle.bundleIdentifier != nil,
              let executable = bundle.executableURL else { return false }
        return executable.deletingLastPathComponent().standardizedFileURL ==
            bundle.bundleURL.appendingPathComponent("Contents/MacOS").standardizedFileURL
    }

    @MainActor static func run(_ action: LaunchOptions.LoginItemAction) throws -> Int32 {
        let bundle = Bundle.main
        let validBundle = isApplicationBundle(bundle)
        // Keep this entry synchronous: awaiting from async main before app.run()
        // can resume GUI startup inside dispatch main and starve AppKit tasks (M4.2).
        // Use the synchronous unregister overload on a utility queue; no run loop
        // or main-actor callback is needed to finish before printing and exiting.
        let (report, exitCode): (Report, Int32) = DispatchQueue.global(qos: .utility).sync {
            guard validBundle else {
                return (Report(status: .notFound, bundlePath: bundle.bundlePath), 2)
            }
            let service = SMAppService.mainApp
            var failure: String?
            do {
                switch action {
                case .on: try service.register()
                case .off: try service.unregister()
                case .status: break
                }
            } catch {
                failure = error.localizedDescription
            }
            let status = service.status
            return (Report(status: status, bundlePath: bundle.bundlePath, failure: failure),
                    failure == nil && status != .notFound ? 0 : 2)
        }
        // A bare executable has no app defaults domain; do not persist into its host's domain.
        let settings = AppSettings(defaults: validBundle ? UserDefaults.standard : nil)
        settings.launchAtLogin = report.registered
        if validBundle { UserDefaults.standard.synchronize() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return exitCode
    }
}
