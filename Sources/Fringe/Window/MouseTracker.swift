import AppKit

/// Reports the pointer location in global screen coordinates, whether or not this
/// app is frontmost, and left-clicks so the collapsed island can open on click
/// rather than hover.
///
/// Event monitors give us low latency updates; the timer is a cheap reconciliation
/// pass for the cases where no move event is delivered (the pointer jumps between
/// spaces, a modal grabs the mouse, the display configuration changes, ...).
/// Mouse-move and mouse-down monitoring need no accessibility permission — only
/// key events do.
@MainActor
final class MouseTracker {
    private let onMove: (NSPoint) -> Void
    private let onPress: (NSPoint) -> Void
    private let onRelease: (NSPoint) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var reconciliationTimer: Timer?

    private static let watchedEvents: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp
    ]

    init(
        onMove: @escaping (NSPoint) -> Void,
        onPress: @escaping (NSPoint) -> Void,
        onRelease: @escaping (NSPoint) -> Void
    ) {
        self.onMove = onMove
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedEvents) { event in
            MainActor.assumeIsolated { self.report(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watchedEvents) { event in
            MainActor.assumeIsolated { self.report(event) }
            return event
        }

        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { self.report() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconciliationTimer = timer
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
    }

    private func report(_ event: NSEvent? = nil) {
        let location = NSEvent.mouseLocation
        onMove(location)

        switch event?.type {
        case .leftMouseDown: onPress(location)
        case .leftMouseUp: onRelease(location)
        default: break
        }
    }
}
