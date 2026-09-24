import AppKit
import SwiftUI

@MainActor
extension NotchWindowController {
    func pointerReleased(at location: NSPoint) {
        if state.panelResize != nil {
            endPanelResize()
            return
        }
        endArrange(at: location)
    }

    func pointerPressed(at location: NSPoint) {
        guard let screen else { return }

        if state.isExpanded {
            if isArranging, beginPanelResize(at: location, on: screen) { return }
            if isArranging {
                beginArrange(at: location, on: screen)
            }
            return
        }

        guard state.mode == .collapsed else { return }
        guard collapsedHotZone(on: screen).contains(location) else { return }

        // The equaliser is a transport control while the island is peeked, so
        // it has to be checked before the click is treated as "open the panel".
        if let toggle = mediaToggleHotZone(on: screen), toggle.contains(location) {
            nowPlaying.togglePlayPause()
            return
        }

        setMode(.expanded)
    }

    /// The equaliser square, in screen coordinates, while the island is showing
    /// media and peeked. Pointer handling lives here rather than in SwiftUI
    /// because the panel is non-activating and does not hit-test reliably.
    func mediaToggleHotZone(on screen: NSScreen) -> NSRect? {
        guard library.occupancy?.claim.action == "playPause" else { return nil }

        let layout = settings.islandLayout(notch: state.metrics.size)
        let body = geometry(on: screen).topCentred(
            state.isHovered
                ? settings.peekSize(notch: state.metrics.size, hasWings: true)
                : settings.collapsedSize(notch: state.metrics.size, hasWings: true)
        )

        // Contents are centred in the peeked body, and the equaliser is centred
        // in the right wing.
        let centre = NSPoint(
            x: body.midX + layout.size.width / 2 - layout.wingWidth / 2,
            y: body.midY
        )
        return NSRect(
            x: centre.x - layout.contentSide / 2,
            y: centre.y - layout.contentSide / 2,
            width: layout.contentSide,
            height: layout.contentSide
        )
    }

    func collapsedHotZone(on screen: NSScreen) -> NSRect {
        // Use the peeked size so the grown region stays inside the hot zone,
        // and so the rest-state island is a little easier to hit from below.
        let size = settings.peekSize(
            notch: state.metrics.size,
            hasWings: library.occupancy != nil
        )
        return geometry(on: screen).hotZone(size, horizontal: settings.collapsedHoverPadding)
    }

    func isHittable(at location: NSPoint) -> Bool {
        guard let screen else { return false }
        if state.isExpanded {
            let size = settings.expandedSize(notch: state.metrics.size)
            return geometry(on: screen).topCentred(size).contains(location)
        }
        return collapsedHotZone(on: screen).contains(location)
    }

    func expandedHotZone(on screen: NSScreen) -> NSRect {
        let padding = settings.expandedHoverPadding
        return geometry(on: screen).hotZone(
            settings.expandedSize(notch: state.metrics.size),
            horizontal: padding,
            bottom: padding
        )
    }

    func scheduleTransition(to mode: NotchState.Mode, after delay: TimeInterval) {
        guard state.mode != mode else {
            cancelPendingTransition()
            return
        }
        guard pendingTransition == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTransition = nil
                self.setMode(mode)
            }
        }
        pendingTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPendingTransition() {
        pendingTransition?.cancel()
        pendingTransition = nil
    }

    func setMode(_ mode: NotchState.Mode) {
        cancelPendingTransition()
        guard state.mode != mode else { return }
        state.mode = mode
        if mode == .collapsed {
            state.isEditing = false
            popRemoveCursor()
            dismissDragPreview()
            state.arrange = nil
            endPanelResize()
        }
        // Scripts only need to run while there is something to look at.
        library.setActive(state.isExpanded)
        if mode == .collapsed {
            syncHover()
        }
    }

    func setHovered(_ hovered: Bool) {
        guard state.isHovered != hovered else { return }
        state.isHovered = hovered
    }

    func syncHover() {
        guard let screen, state.mode == .collapsed else {
            state.isHovered = false
            return
        }
        setHovered(collapsedHotZone(on: screen).contains(NSEvent.mouseLocation))
    }

    func toggle() {
        setMode(state.isExpanded ? .collapsed : .expanded)
    }

    /// Holds the panel open so settings edits can be previewed. Unpinning leaves
    /// it open until the pointer moves away, which the tracker picks up.
    func setPinned(_ pinned: Bool) {
        state.isPinned = pinned
        if pinned {
            setMode(.expanded)
        }
    }
}
