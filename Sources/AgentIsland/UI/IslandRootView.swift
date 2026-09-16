import SwiftUI
import IslandCore

struct IslandRootView: View {
    let store: IslandStore
    let notch: NotchMetrics
    let mode: IslandMode
    var now = Date()
    var animated = true
    var animationsVisible = true
    var refresh: () -> Void = {}
    var settings: () -> Void = {}
    var retry: (AgentKind) -> Void = { _ in }
    var openClaudeSetup: () -> Void = {}
    var copyLogin: (AgentKind) -> Void = { _ in }
    private var config: IslandLayoutConfig { ExpandedView.layoutConfig(store: store, notch: notch) }

    var body: some View {
        let _ = UIRenderMetrics.recordBody()
        let size = IslandLayout.size(for: mode, notch: notch, config: config,
                                     expandedContentHeight: ExpandedView.contentHeight(store: store, notch: notch))
        let shape = NotchShape(bottomRadius: mode == .expanded ? config.expandedBottomRadius : config.collapsedBottomRadius,
                               earRadius: notch.hasNotch ? config.earRadius : 0)
        VStack(spacing: 0) {
            ZStack {
                if mode == .expanded && store.systemMetricOptions.enabled {
                    SystemStatusView(metrics: store.systemMetrics, options: store.systemMetricOptions,
                                     notch: notch, config: config).transition(.opacity)
                } else {
                    CollapsedView(store: store, notch: notch, active: mode == .active,
                                  animated: animated, animationsVisible: animationsVisible).transition(.opacity)
                }
            }
            .animation(animated && animationsVisible ? .easeInOut(duration: 0.2) : nil,
                       value: mode == .expanded && store.systemMetricOptions.enabled)
            if mode == .expanded {
                ExpandedView(store: store, now: now, availableHeight: size.height - notch.notchRect.height,
                             columns: store.sessionLayout(notch: notch).columns,
                             animated: animated, animationsVisible: animationsVisible, refresh: refresh, settings: settings, retry: retry, openClaudeSetup: openClaudeSetup, copyLogin: copyLogin).transition(.islandContent)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        .islandInteraction(.shape(bottomRadius: shape.bottomRadius, earRadius: shape.earRadius))
        .shadow(color: .black.opacity(mode == .expanded ? 0.45 : 0), radius: 18, y: 8)
        .foregroundStyle(Theme.primary)
        .environment(\.colorScheme, .dark)
        .animation(animated && animationsVisible ? .spring(response: mode == .expanded ? 0.42 : 0.32,
                                       dampingFraction: mode == .expanded ? 0.80 : 0.90) : nil, value: mode)
        .animation(animated && animationsVisible ? .spring(response: 0.42, dampingFraction: 0.80) : nil, value: size)
    }
}
