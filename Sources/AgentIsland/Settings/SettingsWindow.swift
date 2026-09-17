import AppKit
import SwiftUI
import ServiceManagement
import IslandCore

@MainActor final class SettingsWindowController {
    private var window: NSWindow?
    let settings: AppSettings
    let store: IslandStore
    let connection: ConnectionActions
    let previewOnly: Bool
    init(settings: AppSettings, store: IslandStore, connection: ConnectionActions, previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        self.settings = settings; self.store = store; self.connection = connection
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "AgentIsland 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScrollView {
                SettingsView(settings: settings, store: store, connection: connection, commandPreviewOnly: previewOnly)
            })
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close(); window = nil }
}

@MainActor @Observable final class ConnectionActions {
    private(set) var setupError: String?
    private(set) var claudeLoginCommand = "claude auth login"
    private(set) var codexLoginCommand = "codex login"
    func resolve() async {
        async let claude = ExecutableLocator.claudeCLI()
        async let codex = ExecutableLocator.codexCLI()
        if let url = await claude { claudeLoginCommand = Self.quote(url.path) + " auth login" }
        if let url = await codex { codexLoginCommand = Self.quote(url.path) + " login" }
    }
    func copy(_ agent: ProviderID) {
        guard let command = loginCommand(for: agent) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    func loginCommand(for agent: ProviderID) -> String? {
        switch agent {
        case .claude: claudeLoginCommand
        case .codex: codexLoginCommand
        default: nil
        }
    }
    func openClaudeSetup() {
        Task {
            setupError = nil
            guard let executable = await ExecutableLocator.claudeCLI(),
                  let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                setupError = "未找到 Claude Code 或终端"; return
            }
            do {
                let command = try await Task.detached(priority: .utility) {
                    let directory = ClaudeRefreshDirectory.url()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let command = directory.deletingLastPathComponent().appendingPathComponent("claude-setup.command")
                    let script = "#!/bin/zsh\ncd " + Self.quote(directory.path) + " || exit 1\nexec " + Self.quote(executable.path) + "\n"
                    try Data(script.utf8).write(to: command, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
                    return command
                }.value
                _ = try await NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: .init())
            } catch { setupError = "无法打开设置终端，请重试" }
        }
    }
    nonisolated private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var settings: AppSettings
    let store: IslandStore
    let connection: ConnectionActions
    var commandPreviewOnly = false
    var customSnapshotForm = false
    var customSnapshotDeletion: ProviderID? = nil
    var snapshot = false
    var snapshotDate = Date()
    @State private var loginBusy = false
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("数据源") {
                ForEach(store.providerStates) { provider in
                    HStack(spacing: 8) {
                        AgentGlyph(agent: provider.id, tint: provider.id == .codex ? codexTint : nil,
                                   descriptor: store.descriptor(for: provider.id), animated: false).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                            Text(provider.statusLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SourceButton("↑") { settings.moveProvider(provider.id, by: -1) }
                            .disabled(settings.declarations.first?.id == provider.id).accessibilityLabel("上移" + provider.name)
                        SourceButton("↓") { settings.moveProvider(provider.id, by: 1) }
                            .disabled(settings.declarations.last?.id == provider.id).accessibilityLabel("下移" + provider.name)
                        if settings.providerOverrides[provider.id] != nil {
                            Button { settings.setProviderOverride(nil, for: provider.id) } label: {
                                Text("恢复自动").font(.system(size: 10)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        toggle(provider.name, enabled: provider.enabled, labelHidden: true) {
                            settings.setProviderOverride(!provider.enabled, for: provider.id)
                        }
                    }
                }
            }
            CustomSourceSettings(settings: settings, store: store, snapshot: snapshot,
                                 previewOnly: commandPreviewOnly, snapshotForm: customSnapshotForm,
                                 snapshotDeletion: customSnapshotDeletion)
            section("额度与会话") {
                HStack {
                    Text("额度显示口径")
                    Spacer()
                    ForEach(QuotaDisplayMode.allCases, id: \.self) { mode in
                        option(mode.label, selected: settings.quotaDisplayMode == mode) { settings.quotaDisplayMode = mode }
                    }
                }
                choice("额度刷新间隔", value: $settings.refreshInterval, options: [30, 60, 120, 300], suffix: "秒")
                number("警告阈值（已用）", value: $settings.warningThreshold, range: 1...(settings.criticalThreshold - 1), suffix: "%")
                number("危险阈值（已用）", value: $settings.criticalThreshold, range: (settings.warningThreshold + 1)...100, suffix: "%")
            }
            section("会话列表") {
                choice("会话活跃时间窗", value: $settings.activeMinutes, options: [15, 30, 60], suffix: "分钟")
                if store.sessionProviderIDs.count == 2 {
                    HStack {
                        Text("布局")
                        Spacer()
                        ForEach(SessionListLayoutMode.allCases, id: \.self) { layout in
                            option(layout.label, selected: settings.sessionListLayout == layout) { settings.sessionListLayout = layout }
                        }
                    }
                }
            }
            section("外观与启动") {
                HStack {
                    Text("展开方式")
                    Spacer()
                    ForEach(ExpansionMethod.allCases, id: \.self) { method in
                        option(method.label, selected: settings.expansionMethod == method) { settings.expansionMethod = method }
                    }
                }
                number("翅膀宽度", value: $settings.wingWidth, range: Double(IslandLayout.minimumWingWidth)...100, suffix: "pt")
                HStack {
                    Text("显示屏幕")
                    Spacer()
                    option("内建刘海屏", selected: !settings.useMainScreen) { settings.useMainScreen = false }
                    option("主屏", selected: settings.useMainScreen) { settings.useMainScreen = true }
                }
                toggle("全屏时显示", enabled: settings.showInFullscreen) { settings.showInFullscreen.toggle() }
                toggle("开机启动", enabled: settings.launchAtLogin, disabled: loginBusy || snapshot) { setLogin(!settings.launchAtLogin) }
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            }
            section("系统指标") {
                toggle("网速", enabled: settings.showNetwork) { settings.showNetwork.toggle() }
                toggle("显示 CPU", enabled: settings.showCPU) { settings.showCPU.toggle() }
                toggle("显示 GPU", enabled: settings.showGPU) { settings.showGPU.toggle() }
                toggle("风扇", enabled: settings.showFan) { settings.showFan.toggle() }
                toggle("内存", enabled: settings.showMemory) { settings.showMemory.toggle() }
            }
            if store.quotaProviderIDs.contains(.claude) {
                section("Claude 连接") {
                    Text(connectionLabel).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let current = snapshot ? snapshotDate : context.date
                        Text(store.claudeConnection?.expiresAt.map {
                            $0 > current ? "登录剩余有效期：" + DisplayTime.duration($0.timeIntervalSince(current)) : "登录已到期，等待续期"
                        } ?? "登录剩余有效期：未知").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(store.claudeConnection?.lastAttempt.map {
                        "上次自动续期：" + DisplayTime.full($0) + " · " + (store.claudeConnection.map { status in
                            status.result == .needsLogin && !status.requiresUserAction ? status.recoveryMessage : status.result?.message ?? "未知"
                        } ?? "未知")
                    } ?? "上次自动续期：暂无").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if store.claudeConnection?.requiresUserAction == true, case .needsUserSetup = store.claudeConnection?.result {
                            Button("打开终端完成设置") { connection.openClaudeSetup() }
                        } else if store.claudeConnection?.requiresUserAction == true, case .needsLogin = store.claudeConnection?.result {
                            Button("复制登录命令") { connection.copy(.claude) }
                        }
                        Button("重试") { Task { await store.retryClaudeConnection() } }
                            .disabled(store.claudeConnection?.isRefreshing == true)
                    }.buttonStyle(.bordered)
                    if let error = connection.setupError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }.font(.system(size: 12)).padding(20).frame(width: 470).frame(minHeight: 820)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { if !snapshot { updateLoginStatus() } }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9, content: content)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func choice(_ title: String, value: Binding<Int>, options: [Int], suffix: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer()
            ForEach(options, id: \.self) { number in
                option("\(number) \(suffix)", selected: value.wrappedValue == number) { value.wrappedValue = number }
            }
        }
    }
    private func number(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) } label: {
                Image(systemName: "minus").frame(width: 24, height: 22)
            }.disabled(value.wrappedValue <= range.lowerBound).accessibilityLabel("减少" + title)
            Text("\(Int(value.wrappedValue)) \(suffix)").monospacedDigit().frame(width: 58)
            Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) } label: {
                Image(systemName: "plus").frame(width: 24, height: 22)
            }.disabled(value.wrappedValue >= range.upperBound).accessibilityLabel("增加" + title)
        }.buttonStyle(.plain)
    }
    // Resolve before AgentGlyph bakes its bitmap; island glyph colors stay unchanged.
    private var codexTint: Color { colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.15) }

    private func toggle(_ title: String, enabled: Bool, disabled: Bool = false, labelHidden: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if !labelHidden {
                    Text(title)
                    Spacer()
                }
                Capsule().fill(enabled ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 30, height: 18)
                    .overlay(alignment: enabled ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                    }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(title).accessibilityValue(enabled ? "开启" : "关闭")
    }
    private var connectionLabel: String {
        if let status = store.claudeConnection, status.isRefreshing || status.isRecovering || status.requiresUserAction {
            return status.recoveryMessage
        }
        return switch store.health[.claude] {
        case .ok: "已连接"
        case let .needsSetup(message): message
        case let .failed(message): message
        case let .stale(date): "数据陈旧 · 最近成功 " + DisplayTime.full(date)
        case .disabled: "已停用"
        case nil: "加载中…"
        }
    }
    private func updateLoginStatus() {
        let status = SMAppService.mainApp.status
        settings.launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval { loginMessage = "请在系统设置的登录项中允许 AgentIsland" }
    }
    private func setLogin(_ enabled: Bool) {
        loginBusy = true; loginMessage = nil
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try await SMAppService.mainApp.unregister() }
                }.value
                updateLoginStatus()
            } catch {
                loginMessage = "开机启动设置失败，请将应用放入“应用程序”后重试，或检查系统登录项权限。"
                updateLoginStatus()
            }
            loginBusy = false
        }
    }
}
