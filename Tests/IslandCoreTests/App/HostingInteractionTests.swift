import AppKit
import SwiftUI
import Observation
import Testing
import IslandCore
@testable import AgentIsland

@MainActor @Test func hostingViewReceivesNonKeyFirstClick() throws {
    _ = NSApplication.shared
    let model = IslandViewModel(store: IslandStore.mock(.idle))
    model.setExpansionMethod(.click)
    let host = IslandHostingView(rootView: IslandRootView(store: model.store,
        notch: SnapshotExporter.metrics(hasNotch: true), mode: .collapsed))
    host.frame = NSRect(x: 0, y: 0, width: 337, height: 32)
    host.primaryClick = { model.togglePinned() }
    let panel = NotchPanel(frame: host.frame)
    panel.contentView = host
    defer { panel.close() }
    host.layoutSubtreeIfNeeded()
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 30, y: 16),
        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    #expect(host.window?.isKeyWindow != true)
    #expect(host.acceptsFirstMouse(for: event))
    #expect(host.hitTest(NSPoint(x: 30, y: 16)) === host)
    host.mouseDown(with: event)
    #expect(model.mode == .expanded)
    #expect(model.interaction.pinned)
    host.mouseDown(with: event)
    #expect(model.mode == .collapsed)
    #expect(!model.interaction.pinned)
    model.setExpansionMethod(.hover)
    model.setHovered(true)
    host.mouseDown(with: event)
    #expect(model.interaction.pinned)
    model.clickedOutside()
    #expect(model.mode == .collapsed)
    model.stop()
}

@MainActor @Test func fiftySessionLayoutRemainsBoundedAndDataDoesNotExpand() {
    let store = IslandStore.mock(.idle)
    let model = IslandViewModel(store: store)
    store.sessions = (0..<50).map {
        AgentSession(agent: .codex, sessionId: "fixture-\($0)", title: "会话 \($0)", phase: .thinking, lastActivityAt: .now)
    }
    #expect(store.sessions.count == 50)
    #expect(model.mode == .active)
    #expect(!model.interaction.expanded)
    for hasNotch in [false, true] {
        let metrics = SnapshotExporter.metrics(hasNotch: hasNotch)
        #expect(ExpandedView.contentHeight(store: store, notch: metrics) <= 400)
    }
}

@MainActor @Test(arguments: [1, 2]) func fiftySessionNativeScrollViewCanReachTheLastRows(columns: Int) async throws {
    _ = NSApplication.shared
    let store = IslandStore.mock(.idle)
    store.sessions = (0..<50).map {
        AgentSession(agent: .claude, sessionId: "scroll-\($0)", title: "滚动测试 \($0)",
                     phase: .waitingInput, lastActivityAt: .now)
    }
    let host = NSHostingView(rootView: ExpandedView(store: store, now: .now, availableHeight: 368, columns: columns,
                                                   animationsVisible: false))
    host.frame = NSRect(x: 0, y: 0, width: columns == 2 ? 900 : 600, height: 368)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    let scroll = try #require(scrollView(in: host))
    let document = try #require(scroll.documentView)
    #expect(document.frame.height > scroll.contentView.bounds.height)
    let before = scroll.contentView.bounds.origin.y
    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    host.layoutSubtreeIfNeeded()
    #expect(scroll.contentView.bounds.origin.y > before)
    #expect(scroll.contentView.bounds.maxY >= document.frame.height - 1)
    #expect(store.sessions.count == 50)
}

@MainActor private struct RoutingIsland: View {
    let model: IslandViewModel
    let notch: NotchMetrics
    let refresh: () -> Void
    let settings: () -> Void

    var body: some View {
        IslandRootView(store: model.store, notch: notch, mode: model.mode,
                       animationsVisible: false, refresh: refresh, settings: settings)
            .transaction { $0.disablesAnimations = true }
    }
}

@MainActor private final class RoutingFixture {
    let model: IslandViewModel
    let panel: NotchPanel
    let host: IslandHostingView<RoutingIsland>
    let notch: NotchMetrics
    var refreshCount = 0
    var settingsCount = 0

    init(hasNotch: Bool = true, sessions: Int = 1) {
        _ = NSApplication.shared
        notch = SnapshotExporter.metrics(hasNotch: hasNotch)
        let store = IslandStore.mock(.idle)
        store.sessions = (0..<sessions).map {
            AgentSession(agent: .codex, sessionId: "routing-\($0)", title: "路由测试 \($0)",
                         phase: .waitingInput, lastActivityAt: .now)
        }
        model = IslandViewModel(store: store)
        host = IslandHostingView(rootView: RoutingIsland(model: model, notch: notch, refresh: {}, settings: {}))
        panel = NotchPanel(frame: .zero)
        host.rootView = IslandInteractionCanvas(content: RoutingIsland(model: model, notch: notch,
            refresh: { [weak self] in self?.refreshCount += 1 },
            settings: { [weak self] in self?.settingsCount += 1 }), geometry: host.interactionGeometry)
        host.primaryClick = { [weak model] in model?.togglePinned() }
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.ignoresMouseEvents = false
    }

    func layout() async throws {
        let size = IslandLayout.size(for: model.mode, notch: notch, config: ExpandedView.layoutConfig(store: model.store, notch: notch),
            expandedContentHeight: ExpandedView.contentHeight(store: model.store, notch: notch))
        let canvas = NSSize(width: size.width + (model.mode == .expanded ? 48 : 0),
                            height: size.height + (model.mode == .expanded ? 36 : 0))
        panel.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: canvas), display: false)
        panel.orderFrontRegardless()
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
    }

    func rect(_ id: String) throws -> CGRect {
        try #require(host.interactionGeometry.regions.first { $0.kind == .control(id) && !$0.rect.isNull }?.rect)
    }

    func shapeRect() throws -> CGRect {
        try #require(host.interactionGeometry.regions.first {
            if case .shape = $0.kind { return true }; return false
        }?.rect)
    }

    // Every integration click enters through NSWindow's real event dispatcher.
    // Deliver both edges so SwiftUI buttons/gestures can finish their interaction.
    func click(_ point: NSPoint) throws {
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        let location = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
    }

    func close() { model.stop(); panel.close() }
}

// Routing tests wait for the observed state transition, independent of hover timer latency.
@MainActor private func waitForHoverExpansion(_ model: IslandViewModel) async {
    while model.mode != .expanded {
        let changed = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = model.mode
        } onChange: {
            changed.continuation.yield(())
            changed.continuation.finish()
        }
        for await _ in changed.stream { break }
    }
}

@MainActor @Test func panelRoutesHeaderAndExpandedBodyClicks() async throws {
    let fixture = RoutingFixture()
    defer { fixture.close() }
    let model = fixture.model
    #expect(!fixture.panel.canBecomeKey && !fixture.panel.canBecomeMain)
    #expect(fixture.panel.styleMask.contains(.nonactivatingPanel))
    #expect(!fixture.panel.isKeyWindow)
    model.setExpansionMethod(.click)
    try await fixture.layout()
    try fixture.click(NSPoint(x: 30, y: 16))
    #expect(model.mode == .expanded)
    #expect(model.interaction.pinned)
    try await fixture.layout()
    let shape = try fixture.shapeRect()
    try fixture.click(NSPoint(x: shape.midX, y: shape.minY + 70))
    #expect(model.mode == .collapsed)
    #expect(!model.interaction.pinned)
    try await fixture.layout()
    model.setExpansionMethod(.hover)
    model.setHovered(true)
    await waitForHoverExpansion(model)
    try await fixture.layout()
    #expect(model.mode == .expanded && !model.interaction.pinned)
    try fixture.click(NSPoint(x: shape.midX, y: shape.minY + 70))
    #expect(model.interaction.pinned)
    try fixture.click(NSPoint(x: shape.midX, y: shape.minY + 70))
    #expect(model.mode == .collapsed && !model.interaction.pinned)
}

@MainActor @Test(arguments: [true, false]) func panelRoutesControlsWithoutPinning(pinned: Bool) async throws {
    let fixture = RoutingFixture()
    defer { fixture.close() }
    if pinned { fixture.model.togglePinned() }
    else {
        fixture.model.setHovered(true)
        await waitForHoverExpansion(fixture.model)
    }
    try await fixture.layout()
    let refresh = try fixture.rect("refresh")
    try fixture.click(NSPoint(x: refresh.midX, y: refresh.midY))
    try await fixture.layout()
    #expect(fixture.refreshCount == 1)
    #expect(fixture.model.interaction.pinned == pinned)
    let settings = try fixture.rect("settings")
    try fixture.click(NSPoint(x: settings.midX, y: settings.midY))
    try await fixture.layout()
    #expect(fixture.settingsCount == 1)
    #expect(fixture.model.interaction.pinned == pinned)
    let session = try #require(fixture.model.store.sessions.first)
    let row = try fixture.rect("session:" + session.id)
    try fixture.click(NSPoint(x: row.midX, y: row.midY))
    try await fixture.layout()
    #expect(fixture.model.store.expandedSessionIDs.contains(session.id))
    #expect(fixture.model.interaction.pinned == pinned)
    let expandedRow = try fixture.rect("session:" + session.id)
    #expect(expandedRow.height == row.height + 64)
    try fixture.click(NSPoint(x: expandedRow.midX, y: expandedRow.minY + 20))
    try await fixture.layout()
    #expect(fixture.model.store.expandedSessionIDs.isEmpty)
    #expect(fixture.model.interaction.pinned == pinned)
}

@MainActor @Test func panelRejectsClicksOutsideIslandShape() async throws {
    for hasNotch in [true, false] {
        let fixture = RoutingFixture(hasNotch: hasNotch)
        defer { fixture.close() }
        for expanded in [false, true] {
            if expanded { fixture.model.togglePinned() }
            try await fixture.layout()
            let rect = try fixture.shapeRect()
            let points = [NSPoint(x: rect.minX + 1, y: rect.maxY - 1),
                          NSPoint(x: 1, y: fixture.host.bounds.height - 1)]
            for point in points {
                #expect(!fixture.host.interactionGeometry.contains(point))
                let local = NSPoint(x: point.x, y: fixture.host.isFlipped ? point.y : fixture.host.bounds.height - point.y)
                #expect(fixture.host.hitTest(fixture.host.convert(local, to: fixture.host.superview)) == nil)
                try fixture.click(point)
                #expect(fixture.model.interaction.pinned == expanded)
            }
        }
    }
}

@MainActor @Test func panelRoutesRowsAfterScrolling() async throws {
    let fixture = RoutingFixture(sessions: 50)
    defer { fixture.close() }
    fixture.model.togglePinned()
    try await fixture.layout()
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    let scroll = try #require(scrollView(in: fixture.host))
    let viewport = try #require(fixture.host.interactionGeometry.regions.first { $0.kind == .scroll }?.rect)
    // Scroll the real SwiftUI document, then dispatch a click at the new reported
    // row position. Wheel delivery itself is covered by the native receiver test.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await fixture.layout()
    #expect(scroll.contentView.bounds.origin.y == 160)
    #expect(fixture.model.interaction.pinned)
    let visible = try #require(fixture.host.interactionGeometry.regions.first {
        if case let .control(id) = $0.kind { return id.hasPrefix("session:") && !$0.rect.isNull && $0.rect.height >= 40 }
        return false
    })
    guard case let .control(id) = visible.kind else { return }
    #expect(viewport.contains(visible.rect))
    for region in fixture.host.interactionGeometry.regions {
        if case let .control(controlID) = region.kind, controlID.hasPrefix("session:"), !region.rect.isNull {
            #expect(viewport.contains(region.rect))
        }
    }
    try fixture.click(NSPoint(x: visible.rect.midX, y: visible.rect.midY))
    try await fixture.layout()
    #expect(fixture.model.store.expandedSessionIDs.contains(String(id.dropFirst("session:".count))))
    #expect(fixture.model.interaction.pinned)
}

@MainActor private final class ScrollReceiver: NSScrollView {
    var wheelCount = 0
    override func scrollWheel(with event: NSEvent) {
        wheelCount += 1
        super.scrollWheel(with: event)
    }
}

@MainActor private struct NativeScrollContent: NSViewRepresentable {
    let scroll: ScrollReceiver
    func makeNSView(context: Context) -> ScrollReceiver { scroll }
    func updateNSView(_ nsView: ScrollReceiver, context: Context) {}
}

@MainActor @Test func panelDeliversWheelToNativeScrollReceiver() async throws {
    _ = NSApplication.shared
    let scroll = ScrollReceiver()
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
    let host = IslandHostingView(rootView: NativeScrollContent(scroll: scroll)
        .islandScrollViewport()
        .islandInteraction(.shape(bottomRadius: 0, earRadius: 0)))
    let panel = NotchPanel(frame: NSRect(x: -10000, y: -10000, width: 200, height: 100))
    var clicks = 0
    host.primaryClick = { clicks += 1 }
    panel.contentView = host
    panel.ignoresMouseEvents = false
    panel.orderFrontRegardless()
    defer { panel.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    host.layoutSubtreeIfNeeded()
    let location = NSPoint(x: 100, y: 50)
    let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                    wheel1: -160, wheel2: 0, wheel3: 0))
    // An unposted CG event has no window. Supply window-local coordinates for
    // direct panel.sendEvent, converting CG's downward Y axis.
    event.location = NSPoint(x: location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - location.y)
    let wheel = try #require(NSEvent(cgEvent: event))
    #expect(wheel.locationInWindow == location)
    panel.sendEvent(wheel)
    #expect(scroll.wheelCount == 1)
    #expect(clicks == 0)
    #expect(panel.routingEventType == nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let click = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
    }
    #expect(clicks == 1)
}
