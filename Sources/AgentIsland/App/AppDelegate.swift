import AppKit
import CoreGraphics
import IslandCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var controller: NotchWindowController?
    private var settingsWindow: SettingsWindowController?
    private var exitTask: Task<Void, Never>?
    private var glyphTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var store: IslandStore?
    private var lastInterval = 0
    private var lastActive = 0
    private var lastMainScreen = false
    private var systemSleeping = false
    private var locked = false
    private var displaySleeping = false
    private var terminating = false
    private var readyToTerminate = false

    init(options: LaunchOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = RuntimeData(options: options)
        let quota = runtime.quota, sessions = runtime.sessions, store = runtime.store
        self.store = store
        locked = Self.screenIsLocked
        let settings = AppSettings(defaults: options.mockScenario == nil ? UserDefaults.standard : nil)
        let connection = ConnectionActions()
        UIRenderMetrics.enabled = options.measure
        let model = IslandViewModel(store: store, forcedState: options.forcedState)
        settingsWindow = SettingsWindowController(settings: settings, store: store, connection: connection)
        let controller = NotchWindowController(model: model, settings: settings, connection: connection)
        controller.openSettings = { [weak self] in self?.settingsWindow?.show() }
        self.controller = controller
        settings.onChange = { [weak self, weak settings] in
            guard let self, let settings else { return }
            self.apply(settings)
        }
        model.setExpansionMethod(settings.expansionMethod)
        settings.apply(to: store)
        lastInterval = settings.refreshInterval; lastActive = settings.activeMinutes; lastMainScreen = settings.useMainScreen
        controller.show()
        controller.setSystemSleeping(systemSleeping || locked || displaySleeping)
        if options.mockScenario == nil { model.enableSystemMetrics() }
        glyphTask = Task { await BrandGlyphLoader.shared.refresh() }
        lifecycleTask = Task {
            await store.setVisible(!systemSleeping && !locked && !displaySleeping)
            await store.configure(interval: Double(settings.refreshInterval), activeWindow: Double(settings.activeMinutes * 60))
            guard !Task.isCancelled else { return }
            await store.start()
        }
        if options.mockScenario == nil { connectionTask = Task { await connection.resolve() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(lock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(unlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        if options.measure {
            exitTask = Task {
                await Measure.run(store: store, quota: quota, sessions: sessions, presentation: controller.panel == nil ? "headless" : "window", realData: options.mockScenario == nil, seconds: options.exitAfter ?? 60)
                NSApp.terminate(nil)
            }
        } else if let seconds = options.exitAfter {
            exitTask = Task {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                NSApp.terminate(nil)
            }
        }
    }

    private func apply(_ settings: AppSettings) {
        guard let store else { return }
        controller?.model.setExpansionMethod(settings.expansionMethod)
        settings.apply(to: store)
        controller?.model.updateSystemMetrics()
        controller?.refreshVisibility()
        if lastMainScreen != settings.useMainScreen {
            lastMainScreen = settings.useMainScreen
            controller?.reposition()
        }
        guard lastInterval != settings.refreshInterval || lastActive != settings.activeMinutes else { return }
        lastInterval = settings.refreshInterval; lastActive = settings.activeMinutes
        let interval = Double(lastInterval), active = Double(lastActive * 60), previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await store.configure(interval: interval, activeWindow: active)
        }
    }
    @objc private func sleep() { recordLifecycle(.sleep); systemSleeping = true; updateSuspension() }
    private static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    @objc private func wake() {
        recordLifecycle(.wake)
        controller?.model.updateSystemMetrics(reset: true)
        systemSleeping = false; locked = Self.screenIsLocked; updateSuspension(retryClaude: true)
    }
    @objc private func displaySleep() { recordLifecycle(.displaySleep); displaySleeping = true; updateSuspension() }
    @objc private func displayWake() { recordLifecycle(.displayWake); displaySleeping = false; locked = Self.screenIsLocked; updateSuspension() }
    @objc private func lock() { recordLifecycle(.lock); locked = true; updateSuspension() }
    @objc private func unlock() { recordLifecycle(.unlock); locked = false; updateSuspension(retryClaude: true) }
    @objc private func clockChanged() {
        guard !systemSleeping, !locked, !displaySleeping else { return }
        Task { await store?.refreshNow() }
    }
    private func recordLifecycle(_ event: ClaudeDiagnostics.Event) {
        guard options.mockScenario == nil else { return }
        Task { await ClaudeDiagnostics.shared.record(event) }
    }
    private func updateSuspension(retryClaude: Bool = false) {
        let suspended = systemSleeping || locked || displaySleeping
        controller?.setSystemSleeping(suspended)
        guard !terminating, let store else { return }
        let previous = visibilityTask
        visibilityTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            if retryClaude { await store.detectProviders(); await store.retryClaudeConnection() }
            await store.setVisible(!suspended)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        exitTask?.cancel(); connectionTask?.cancel(); glyphTask?.cancel()
        controller?.stop(); settingsWindow?.close()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        lifecycleTask?.cancel(); settingsTask?.cancel(); visibilityTask?.cancel()
        let previous = lifecycleTask, configuration = settingsTask, visibility = visibilityTask
        Task {
            await store?.stop()
            await previous?.value; await configuration?.value; await visibility?.value
            finishTermination()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.readyToTerminate else { return }
            FileHandle.standardError.write(Data("AgentIsland：退出清理超过 1 秒，结束应用。\n".utf8))
            self.finishTermination()
        }
        // terminateLater enters AppKit's termination run-loop mode, where Swift's
        // main-executor cleanup task may never run. Cancel this request, clean up in
        // the normal run loop, then issue a second request that returns terminateNow.
        return .terminateCancel
    }
    private func finishTermination() {
        guard !readyToTerminate else { return }
        readyToTerminate = true
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        exitTask?.cancel(); connectionTask?.cancel(); glyphTask?.cancel()
        controller = nil; settingsWindow = nil
    }
}
