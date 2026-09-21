import AppKit
import SwiftUI
import IslandCore

@main @MainActor struct AgentIslandEntry {
    static func main() async {
        let processStarted = ContinuousClock.now
        do {
            var options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            options.processStarted = processStarted
            if options.help { print(LaunchOptions.helpText); return }
            if let action = options.loginItem {
                exit(try LoginItemCommand.run(action))
            }
            if options.dump == "claude-log" {
                await DumpClaudeLog.run(home: options.home)
                return
            }
            if options.dump == "providers" {
                try await DumpProviders.run(home: options.home, mock: options.mockScenario)
                return
            }
            if options.dump == "system" {
                try await DumpSystem.run()
                return
            }
            if options.dump == "sessions" {
                try await DumpSessions.run(home: options.home)
                return
            }
            if options.dump == "quota" {
                exit(await DumpQuota.run(home: options.home, mock: options.mockScenario))
            }
            if options.dump != nil {
                print("{\"error\":\"not implemented\"}")
                exit(2)
            }
            if options.measure || options.exitAfter != nil {
                // Independent of the main executor and service cancellation. A stuck teardown
                // must not leave an audit overlay running indefinitely; 124 denotes timeout.
                let limit = options.exitAfter ?? 60
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit + 3) {
                    FileHandle.standardError.write(Data("AgentIsland：退出清理超时，强制结束。\n".utf8))
                    exit(124)
                }
            }
            if options.snapshotDirectory != nil || options.snapshotAnimationDirectory != nil {
                try SnapshotExporter.validateRenderingDevice()
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if options.printGeometry {
                guard let geometry = NotchGeometry.preferred() else {
                    print("{\"error\":\"NSScreen 未返回可用屏幕；请在桌面会话中运行\"}")
                    exit(2)
                }
                let object = geometry.json()
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            if let directory = options.snapshotDirectory {
                try await SnapshotExporter.export(to: directory)
                return
            }
            if let directory = options.snapshotAnimationDirectory {
                try await SnapshotAnimationExporter.export(to: directory)
                return
            }
            if options.measure, NotchGeometry.preferred() == nil {
                await Measure.headless(options: options)
                return
            }
            guard NotchGeometry.preferred() != nil else {
                FileHandle.standardError.write(Data("AgentIsland：NSScreen 未返回可用屏幕，无法启动浮层。\n".utf8))
                exit(2)
            }
            runGUI(options: options, app: app)
        } catch {
            report(error)
            exit(2)
        }
    }
    // NSApplication.run must be entered without suspending the GUI startup path.
    // Resuming from an await enters via a dispatch main callback and can starve
    // main-actor service/termination tasks inside AppKit's nested run loop.
    // Keep this function synchronous; async audit branches above must return.
    static func runGUI(options: LaunchOptions, app: NSApplication) {
        let delegate = AppDelegate(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func report(_ error: any Error) {
        FileHandle.standardError.write(Data("AgentIsland：\(error)\n".utf8))
    }
}
