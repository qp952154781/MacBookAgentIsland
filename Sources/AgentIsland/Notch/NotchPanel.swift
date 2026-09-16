import AppKit

final class NotchPanel: NSPanel {
    private(set) var routingEventType: NSEvent.EventType?

    override func sendEvent(_ event: NSEvent) {
        // Keep hit testing aware of the dispatched event, including direct
        // sendEvent callers for which NSApp.currentEvent is not populated.
        let previous = routingEventType
        routingEventType = event.type
        defer { routingEventType = previous }
        super.sendEvent(event)
    }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
