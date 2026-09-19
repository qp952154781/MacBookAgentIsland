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
    var retry: (ProviderID) -> Void = { _ in }
    var openClaudeSetup: () -> Void = {}
    var copyLogin: (ProviderID) -> Void = { _ in }
    @State private var renderedPresentation: IslandMotionPresentation?
    @State private var expandedContentVisible: Bool?
    private var config: IslandLayoutConfig { ExpandedView.layoutConfig(store: store, notch: notch) }

    var body: some View {
        let _ = UIRenderMetrics.recordBody()
        let target = IslandMotionPresentation(mode: mode,
            size: IslandLayout.size(for: mode, notch: notch, config: config,
                                    expandedContentHeight: ExpandedView.contentHeight(store: store, notch: notch)))
        let rendered = renderedPresentation ?? target
        let showsExpandedContent = expandedContentVisible ?? (mode == .expanded)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shape = NotchShape(bottomRadius: rendered.mode == .expanded ? config.expandedBottomRadius : config.collapsedBottomRadius,
                               earRadius: notch.hasNotch ? config.earRadius : 0)
        VStack(spacing: 0) {
            if showsExpandedContent {
                VStack(spacing: 0) {
                    if store.expandedMetricOptions.enabled {
                        SystemStatusView(metrics: store.systemMetrics, options: store.expandedMetricOptions,
                                         notch: notch, config: config)
                    } else {
                        CollapsedView(store: store, notch: notch, active: false,
                                      animated: animated, animationsVisible: animationsVisible)
                    }
                    ExpandedView(store: store, now: now, availableHeight: rendered.size.height - notch.notchRect.height,
                                 columns: store.sessionLayout(notch: notch).columns,
                                 animated: animated, animationsVisible: animationsVisible, refresh: refresh, settings: settings,
                                 retry: retry, openClaudeSetup: openClaudeSetup, copyLogin: copyLogin)
                }
                .transition(IslandMotion.contentTransition(reduceMotion: reduceMotion))
            } else if rendered.mode != .expanded, config.collapsedStyle == .wings {
                CollapsedView(store: store, notch: notch, active: rendered.mode == .active,
                              animated: animated, animationsVisible: animationsVisible)
            }
        }
        .frame(width: rendered.size.width, height: rendered.size.height, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        .islandInteraction(.shape(bottomRadius: shape.bottomRadius, earRadius: shape.earRadius))
        .shadow(color: .black.opacity(rendered.mode == .expanded ? 0.45 : 0), radius: 18, y: 8)
        .foregroundStyle(Theme.primary)
        .environment(\.colorScheme, .dark)
        .onAppear {
            if renderedPresentation == nil { renderedPresentation = target }
            if expandedContentVisible == nil { expandedContentVisible = mode == .expanded }
        }
        .onChange(of: target) { oldValue, newValue in
            updatePresentation(from: renderedPresentation ?? oldValue, to: newValue, reduceMotion: reduceMotion)
        }
        .onChange(of: animationsVisible) { _, visible in
            guard !visible else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                renderedPresentation = target
                expandedContentVisible = target.mode == .expanded
            }
        }
    }

    private func updatePresentation(from old: IslandMotionPresentation, to new: IslandMotionPresentation,
                                    reduceMotion: Bool) {
        let direction = IslandMotion.direction(from: old, to: new)
        guard animated, animationsVisible else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                renderedPresentation = new
                expandedContentVisible = new.mode == .expanded
            }
            return
        }
        withAnimation(IslandMotion.shapeAnimation(for: direction, reduceMotion: reduceMotion)) {
            renderedPresentation = new
        }
        if old.mode != .expanded, new.mode == .expanded {
            withAnimation(IslandMotion.contentAnimation(appearing: true, reduceMotion: reduceMotion)) {
                expandedContentVisible = true
            }
        } else if old.mode == .expanded, new.mode != .expanded {
            withAnimation(IslandMotion.contentAnimation(appearing: false, reduceMotion: reduceMotion)) {
                expandedContentVisible = false
            }
        } else if new.mode == .expanded {
            expandedContentVisible = true
        }
    }
}
