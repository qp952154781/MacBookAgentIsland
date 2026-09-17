import SwiftUI
import IslandCore

struct QuotaCard: View {
    let agent: ProviderID
    let snapshot: QuotaSnapshot?
    let health: ProviderHealth?
    let now: Date
    var descriptor: ProviderDescriptor? = nil
    var connection: ClaudeConnectionStatus? = nil
    var credentialsPresent: Bool? = nil
    var openSetup: () -> Void = {}
    var diagnostic: String? = nil
    var height: CGFloat = 134
    var warning: Double = 70
    var critical: Double = 90
    var displayMode: QuotaDisplayMode = .remaining
    var retry: () -> Void = {}
    var copyLogin: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentGlyph(agent: agent, descriptor: descriptor, animated: false).frame(width: 16, height: 16)
                Text(descriptor?.displayName ?? ProviderRegistry.descriptor(for: agent).displayName).lineLimit(1).font(Theme.font(12, weight: .semibold))
                if let plan = snapshot?.plan {
                    Text(plan.capitalized).lineLimit(1).font(Theme.font(9, weight: .medium)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(.white.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 0)
                Circle().fill(healthColor).frame(width: 4, height: 4)
                Text(healthLabel).help(diagnostic ?? healthLabel).font(Theme.font(9)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }.frame(height: 18)
            Group {
                if (connection?.isRefreshing == true || connection?.isRecovering == true), connection?.requiresUserAction != true {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ClaudeOAuthUsageClient.recoveringMessage).font(Theme.font(10)).foregroundStyle(Theme.secondary)
                        if let snapshot {
                            if snapshot.windows.count > 4 {
                                ScrollView { windowRows(snapshot) }.scrollIndicators(.hidden).islandScrollViewport()
                            } else { windowRows(snapshot) }
                        } else {
                            Button("重试", action: retry).font(Theme.font(10)).islandInteraction(.control("retry:claude"))
                        }
                    }
                } else if connection?.requiresUserAction == true, case let .needsUserSetup(reason) = connection?.result {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).lineLimit(2)
                        Text("岛会每 30 分钟自动重试").foregroundStyle(Theme.tertiary)
                        HStack {
                            Button("打开终端完成设置", action: openSetup).islandInteraction(.control("claude-setup"))
                            Button("重试", action: retry).islandInteraction(.control("retry:claude"))
                        }
                    }.font(Theme.font(10))
                } else if connection?.requiresUserAction == true, case .needsLogin = connection?.result {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(connection?.credentialsMissing == true ? "未连接 · 请在终端运行 claude auth login" : "Claude 登录已失效，请重新登录").lineLimit(2)
                        HStack {
                            Button("复制登录命令", action: copyLogin).islandInteraction(.control("login:claude"))
                            Button("重试", action: retry).islandInteraction(.control("retry:claude"))
                        }
                    }.font(Theme.font(10))
                } else { switch health {
                case let .needsSetup(message):
                    VStack(alignment: .leading, spacing: 5) {
                        let canRecover = agent == .claude && credentialsPresent == true
                        Text(canRecover ? ClaudeOAuthUsageClient.recoveringMessage : "未连接 · " + message).lineLimit(2)
                        Text(canRecover ? "岛会自动重试连接" : "请先登录 \(ProviderRegistry.descriptor(for: agent).displayName) 后刷新").foregroundStyle(Theme.tertiary)
                        if canRecover {
                            Button("重试", action: retry).islandInteraction(.control("retry:claude"))
                        } else {
                            Button("复制登录命令", action: copyLogin).islandInteraction(.control("login:" + agent.rawValue))
                        }
                    }.font(Theme.font(10))
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).lineLimit(2).foregroundStyle(Theme.secondary)
                        Button("重试", action: retry).islandInteraction(.control("retry:" + agent.rawValue))
                    }.font(Theme.font(10))
                case .disabled:
                    Text("已停用").font(Theme.font(11)).foregroundStyle(Theme.secondary)
                default:
                    if let snapshot {
                        if snapshot.windows.count > 4 {
                            ScrollView { windowRows(snapshot) }.scrollIndicators(.hidden).islandScrollViewport()
                        } else { windowRows(snapshot) }
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("加载中…").font(Theme.font(11)).foregroundStyle(Theme.secondary)
                            Capsule().fill(.white.opacity(0.08)).frame(width: 180, height: 6)
                            Capsule().fill(.white.opacity(0.05)).frame(width: 120, height: 6)
                        }.accessibilityLabel("额度加载中")
                    }
                }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity).frame(height: height)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func windowRows(_ snapshot: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if connection?.isRefreshing == true || connection?.isRecovering == true {
                Text("数据陈旧 · \(max(0, Int(now.timeIntervalSince(snapshot.fetchedAt) / 60))) 分钟前")
                    .font(Theme.font(9)).foregroundStyle(Theme.secondary)
            }
            ForEach(snapshot.windows) { quotaRow($0) }
            if let note = snapshot.note { Text(note).font(Theme.font(9)).foregroundStyle(Theme.secondary).lineLimit(1).help(note) }
            if snapshot.source == .customCommand, let diagnostic {
                Text(diagnostic).font(Theme.font(9)).foregroundStyle(Theme.warning).lineLimit(1).help(diagnostic)
            }
            if let note = displayMode.fallbackNote(snapshot) {
                Text(note).font(Theme.font(9)).foregroundStyle(Theme.secondary)
            }
            if snapshot.windows.count <= 1 {
                if let reset = snapshot.headline?.resetsAt, reset > now {
                    Text("重置于 " + DisplayTime.full(reset)).font(Theme.font(9)).foregroundStyle(Theme.tertiary)
                }
                Text(snapshot.source.label + " · " + DisplayTime.clock(snapshot.fetchedAt) + " 更新")
                    .font(Theme.font(9)).foregroundStyle(Theme.tertiary)
            }
        }
    }
    private var healthColor: Color {
        if connection?.isRefreshing == true || connection?.isRecovering == true || connection?.requiresUserAction == true { return Theme.warning }
        return switch health {
        case .ok: .green.opacity(0.8)
        case .failed: Theme.critical
        default: Theme.tertiary
        }
    }
    private var healthLabel: String {
        if connection?.isRefreshing == true || (connection?.isRecovering == true && connection?.requiresUserAction != true) { return "自动恢复中" }
        if connection?.credentialsMissing == true { return "未连接" }
        if connection?.requiresUserAction == true { return connection?.result == .needsLogin ? "需登录" : "待设置" }
        return switch health {
        case .ok: snapshot.map { DisplayTime.duration(now.timeIntervalSince($0.fetchedAt)) } ?? "已连接"
        case let .stale(lastSuccess): "数据陈旧 · \(max(0, Int(now.timeIntervalSince(lastSuccess) / 60))) 分钟前"
        case .failed: "连接失败"
        case .disabled: "已停用"
        case .needsSetup: "未连接"
        case nil: "加载中"
        }
    }
    private func quotaRow(_ window: QuotaWindow) -> some View {
        HStack(spacing: 5) {
            Text(window.label).font(Theme.font(10)).foregroundStyle(Theme.secondary)
                .frame(width: 73, alignment: .leading).lineLimit(1).help(window.label)
            if let value = window.valueText {
                Text(value).font(Theme.font(11, weight: .semibold)).foregroundStyle(color(window))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09)).frame(height: 6)
                    Capsule().fill(color(window))
                        .frame(width: geometry.size.width * displayMode.fillFraction(window), height: 6)
                    if let pace = displayMode.paceFraction(window, now: now) {
                        Rectangle().fill(displayMode.isAheadOfPace(window, now: now) ? Theme.warning : .white.opacity(0.7))
                            .frame(width: 1, height: 10)
                            .offset(x: min(geometry.size.width - 1, geometry.size.width * pace))
                    }
                }.frame(height: 6)
            }.frame(height: 6).help(displayMode == .remaining ? "均速刻度：按时间进度应剩余额度；低于刻度表示超速" : "均速刻度：按时间进度应已用额度；超过刻度表示超速")
            Text(displayMode.percent(window, expanded: true)).font(Theme.font(10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color(window)).frame(width: displayMode == .remaining ? 48 : 30, alignment: .trailing)
            }
            Text(DisplayTime.reset(window.resetsAt, now: now)).font(Theme.font(9)).monospacedDigit()
                .foregroundStyle(Theme.tertiary).frame(width: 62, alignment: .trailing)
                .help(DisplayTime.resetHelp(window.resetsAt, now: now))
        }.frame(height: 20)
    }
    private func color(_ window: QuotaWindow) -> Color {
        Theme.quota(window, agent: agent, warningThreshold: warning, criticalThreshold: critical, descriptor: descriptor)
    }
}
