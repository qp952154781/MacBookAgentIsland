import AppKit
import SwiftUI
import IslandCore

@MainActor final class HoverTracker {
    private weak var panel: NotchPanel?
    private let model: IslandViewModel
    private let notch: NotchMetrics
    private var cachedConfig: IslandLayoutConfig?
    private var cachedMode: IslandMode?
    private var cachedContentHeight: CGFloat?
    private var frame = CGRect.zero
    private var hoverFrame = CGRect.zero
    private var path = Path()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(panel: NotchPanel, model: IslandViewModel, notch: NotchMetrics) {
        self.panel = panel
        self.model = model
        self.notch = notch
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                          .leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.handle(event) }
        refreshGeometry()
    }

    // Screen geometry changes replace this tracker; presentation changes invalidate the path.
    func refreshGeometry() {
        let contentHeight = ExpandedView.contentHeight(store: model.store, notch: notch)
        let config = ExpandedView.layoutConfig(store: model.store, notch: notch)
        if cachedMode != model.mode || cachedContentHeight != contentHeight || cachedConfig != config {
            cachedConfig = config
            cachedMode = model.mode
            cachedContentHeight = contentHeight
            frame = IslandLayout.frame(for: model.mode, notch: notch, config: config, expandedContentHeight: contentHeight)
            let shape = NotchShape(bottomRadius: model.mode == .expanded ? config.expandedBottomRadius : config.collapsedBottomRadius,
                                   earRadius: notch.hasNotch ? config.earRadius : 0)
            path = shape.path(in: CGRect(origin: .zero, size: frame.size))
            // Hover tolerance never captures clicks outside the actual shape.
            hoverFrame = frame
            if model.mode == .collapsed || model.mode == .active {
                hoverFrame.origin.y -= 6
                hoverFrame.size.height += 6
            }
        }
        update(allowHover: false)
    }

    func update(allowHover: Bool = true) {
        let point = NSEvent.mouseLocation
        panel?.ignoresMouseEvents = !contains(point)
        if allowHover { model.setHovered(panel?.isVisible == true && hoverFrame.contains(point)) }
    }

    func contains(_ point: CGPoint) -> Bool {
        let localPoint = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return frame.contains(point) && path.contains(localPoint)
    }

    private func handle(_ event: NSEvent) {
        update()
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), panel?.ignoresMouseEvents == true {
            model.clickedOutside()
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}
