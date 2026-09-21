import AppKit

/// A transparent, borderless panel that floats above the menu bar and follows the
/// pointer across spaces and full-screen apps.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // One step above the menu bar so the panel can cover the notch itself.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Keeps SwiftUI's hover effects live while another app is frontmost.
        acceptsMouseMovedEvents = true
        // Must be false, or `makeKey()` below is ignored. Hover works without
        // key status because tracking areas do not need it, but drag gestures
        // do — which is why tiles could be hovered and not dragged.
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// SwiftUI controls inside a non-activating panel miss mouse-up unless this
    /// window is already key. Promote it on the way in, then deliver the event.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

/// Irregular window hit-testing: only the notch silhouette takes clicks. The rest
/// of the panel window is empty space and must not swallow menu-bar clicks.
final class NotchHitView: NSView {
    var isPointHittable: (NSPoint) -> Bool = { _ in false }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        guard isPointHittable(screenPoint) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
