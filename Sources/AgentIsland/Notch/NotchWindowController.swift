import AppKit
import SwiftUI
import IslandCore

@MainActor final class NotchWindowController: NSObject {
    let model: IslandViewModel
    let settings: AppSettings
    let connection: ConnectionActions
    var openSettings: () -> Void = {}
    private(set) var panel: NotchPanel?
    private var hover: HoverTracker?
    private var notch: NotchMetrics?
    private var displaySleeping = false
    private var systemSuspended = false
    private var visibilityTask: Task<Void, Never>?
    private var screen: NSScreen?
    private var stopped = false
    private var observing = false
    private var resizeTask: Task<Void, Never>?
    private var presentationObservation: NSKeyValueObservation?

    init(model: IslandViewModel, settings: AppSettings, connection: ConnectionActions) {
        self.model = model
        self.settings = settings; self.connection = connection
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(frontApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(displaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(refreshVisibility), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibility),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshVisibility() }
        }
    }

    func show() { reposition() }

    @objc func reposition() {
        guard let geometry = NotchGeometry.preferred(useMainScreen: settings.useMainScreen) else { return }
        let notch = geometry.metrics
        self.notch = notch
        screen = geometry.screen
        let panel = self.panel ?? NotchPanel(frame: .zero)
        self.panel = panel
        updateFrame()
        let host = IslandHostingView(rootView: LiveIslandView(model: model, notch: notch, openSettings: openSettings, connection: connection,
                                                              geometryChanged: { [weak self] in self?.updateFrame(); self?.hover?.refreshGeometry() }))
        host.primaryClick = { [weak model] in model?.togglePinned() }
        host.contextMenuProvider = { [weak self] in self?.makeMenu() }
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        hover?.stop()
        hover = HoverTracker(panel: panel, model: model, notch: notch)
        hover?.start()
        refreshVisibility()
        observePresentation()
    }

    private func updateFrame(settled: Bool = false) {
        guard let notch, let panel else { return }
        let size = IslandLayout.size(for: model.mode, notch: notch, config: ExpandedView.layoutConfig(store: model.store, notch: notch),
                                    expandedContentHeight: ExpandedView.contentHeight(store: model.store, notch: notch))
        // Retain shadow space only while expanded; collapsed backing stores are just 337 × 36 pt.
        var canvas = CGSize(width: size.width + (model.mode == .expanded ? 48 : 0),
                            height: size.height + (model.mode == .expanded ? 36 : 0))
        resizeTask?.cancel()
        // Keep the old backing width until the SwiftUI spring finishes shrinking.
        // Growth gets its full canvas immediately, with the shape animating inside it.
        if !settled, model.mode == .expanded, panel.frame.width > canvas.width,
           panel.frame.width <= IslandLayout.maximumCenteredWidth(notch: notch) + 48 {
            canvas.width = panel.frame.width
            resizeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                self?.updateFrame(settled: true)
                self?.hover?.refreshGeometry()
            }
        }
        let frame = CGRect(x: notch.notchRect.midX - canvas.width / 2, y: notch.screenFrame.maxY - canvas.height,
                           width: canvas.width, height: canvas.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    // Geometry follows Store changes directly, including the first activity frame.
    private func observePresentation() {
        guard !stopped, !observing, let notch else { return }
        observing = true
        withObservationTracking {
            _ = model.mode
            _ = model.store.wingWidth
            _ = model.store.sessionLayout(notch: notch)
            _ = ExpandedView.contentHeight(store: model.store, notch: notch)
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.observing = false
                self.updateFrame()
                self.hover?.refreshGeometry()
                self.panel?.contentView?.needsLayout = true
                self.panel?.displayIfNeeded()
                self.observePresentation()
            }
        }
    }

    @objc private func displaySleep() { displaySleeping = true; updateSuspension() }
    @objc private func displayWake() { displaySleeping = false; updateSuspension() }
    func setSystemSleeping(_ sleeping: Bool) {
        systemSuspended = sleeping
        updateSuspension()
    }
    private func updateSuspension() {
        if displaySleeping || systemSuspended { visibilityTask?.cancel(); model.clickedOutside(); hover?.stop() }
        else { hover?.stop(); hover?.start() }
        refreshVisibility()
    }
    @objc private func frontApplicationChanged() {
        refreshVisibility()
        visibilityTask?.cancel()
        guard !displaySleeping, !systemSuspended else { return }
        visibilityTask = Task { [weak self] in
            // Full-screen transitions can finish after application activation.
            for _ in 0..<3 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refreshVisibility()
            }
        }
    }
    @objc func refreshVisibility() {
        guard let screen, let panel else { return }
        let menuHidden = screen.frame.maxY - screen.visibleFrame.maxY < 1
        let visible = !displaySleeping && !systemSuspended && (settings.showInFullscreen || !menuHidden)
        if visible && !panel.isVisible { panel.orderFrontRegardless() }
        if !visible && panel.isVisible { panel.orderOut(nil); model.clickedOutside() }
        model.animationsVisible = visible && panel.occlusionState.contains(.visible)
    }

    func stop() {
        stopped = true
        visibilityTask?.cancel()
        resizeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        presentationObservation = nil
        hover?.stop()
        hover = nil
        model.stop()
        panel?.close()
        panel = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshData), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AgentIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func refreshData() { Task { await model.store.refreshNow() } }
    @objc private func showSettings() { openSettings() }
}

final class IslandHostingView<Content: View>: NSHostingView<IslandInteractionCanvas<Content>> {
    let interactionGeometry: IslandInteractionGeometry
    var primaryClick: (() -> Void)?

    init(rootView: Content) {
        let geometry = IslandInteractionGeometry()
        interactionGeometry = geometry
        super.init(rootView: IslandInteractionCanvas(content: rootView, geometry: geometry))
    }

    @available(*, unavailable)
    required init(rootView: IslandInteractionCanvas<Content>) { fatalError("Use the content initializer") }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use the content initializer") }

    private func canvasPoint(_ local: NSPoint) -> NSPoint {
        NSPoint(x: local.x - bounds.minX, y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let canvas = canvasPoint(local)
        guard bounds.contains(local), interactionGeometry.contains(canvas) else { return nil }
        // Scroll wheels must reach the native scroll view even over non-control content.
        let eventType = (window as? NotchPanel)?.routingEventType ?? NSApp.currentEvent?.type
        if eventType == .scrollWheel || interactionGeometry.isControl(canvas) {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = canvasPoint(convert(event.locationInWindow, from: nil))
        guard interactionGeometry.contains(point), !interactionGeometry.isControl(point) else { return }
        primaryClick?()
    }
    var contextMenuProvider: (() -> NSMenu?)?
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func draw(_ dirtyRect: NSRect) { UIRenderMetrics.recordDraw(); super.draw(dirtyRect) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct LiveIslandView: View {
    let model: IslandViewModel
    let notch: NotchMetrics
    let openSettings: () -> Void
    let connection: ConnectionActions
    let geometryChanged: () -> Void
    var body: some View {
        Group {
            if model.mode == .expanded && model.animationsVisible {
                TimelineView(.periodic(from: .now, by: 60)) { context in island(now: context.date) }
            } else { island(now: .now) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.mode) { await BrandGlyphLoader.shared.refresh() }
        .onChange(of: model.mode) { geometryChanged() }
        .onChange(of: model.store.wingWidth) { geometryChanged() }
        .onChange(of: model.store.sessionLayout(notch: notch)) { geometryChanged() }
        .onChange(of: ExpandedView.contentHeight(store: model.store, notch: notch)) { geometryChanged() }

    }
    private func island(now: Date) -> some View {
        IslandRootView(store: model.store, notch: notch, mode: model.mode, now: now,
                       animationsVisible: model.animationsVisible,
                       refresh: { Task { await model.store.refreshNow() } }, settings: openSettings,
                       retry: { agent in Task { if agent == .claude { await model.store.retryClaudeConnection() } else { await model.store.refreshNow(agent: agent) } } },
                       openClaudeSetup: { connection.openClaudeSetup() }, copyLogin: { connection.copy($0) })
    }
}
