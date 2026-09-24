import AppKit
import AudioToolbox
import SwiftUI

@MainActor
extension NotchWindowController {
    /// Hide, don't delete: the script stays on disk and in the settings list,
    /// matching the Dock (the app is not in the trash, just off the strip).
    func hideWidget(_ id: String) {
        playDockPoof()
        withAnimation(.easeIn(duration: 0.16)) {
            settings.setEnabled(false, for: id)
            settings.clearPosition(for: id)
        }
        commitBoard()
        state.hoveredRemove = nil
        state.hoveredWidget = nil
        state.hoveredGrip = nil
    }

    func removeArrangedWidget(_ session: NotchState.ArrangeSession) {
        var dying = session
        dying.isSettling = true
        dying.isRemoving = true

        playDockPoof()
        withAnimation(.easeIn(duration: 0.16)) {
            state.arrange = dying
            settings.setEnabled(false, for: session.widgetID)
            settings.clearPosition(for: session.widgetID)
        } completion: { [weak self] in
            guard let self else { return }
            self.commitBoard()
            self.dismissDragPreview()
            if self.state.arrange?.widgetID == session.widgetID,
               self.state.arrange?.isSettling == true {
                self.state.arrange = nil
            }
        }
    }

    /// Write the previewed cell into settings. Until this runs, packing is
    /// only a proposal — shrinking a resize back, or dragging off a neighbour
    /// and away again, puts them back where they were.
    func commitLanding(_ session: NotchState.ArrangeSession) {
        guard let target = session.landing else {
            commitBoard()
            return
        }
        evictOverlaps(of: target, excluding: session.widgetID)
        settings.setSpan(target.span, for: session.widgetID)
        settings.setPosition(target.slot, for: session.widgetID)
        commitBoard()
    }

    func placeArrangedWidget(_ session: NotchState.ArrangeSession) {
        let grid = settings.grid
        let dropped = CGPoint(
            x: session.originRect.minX + session.translation.width,
            y: session.originRect.minY + session.translation.height
        )
        var session = session
        let target = session.landing ?? WidgetPlacement(
            slot: grid.slot(snapping: dropped, span: session.baseSpan),
            span: session.baseSpan
        )
        session.landing = target
        let settled = grid.rect(for: target)

        // Commit the cell and rebase the offset together and unanimated, so
        // the tile stays under the cursor instead of snapping back to where
        // the drag started and sliding in from there.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            commitLanding(session)

            var rebased = session
            rebased.isSettling = true
            rebased.isRemoving = false
            rebased.translation = CGSize(
                width: session.originRect.minX + session.translation.width - settled.minX,
                height: session.originRect.minY + session.translation.height - settled.minY
            )
            state.arrange = rebased
        }

        // Next tick, so the rebase renders before the spring starts.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                self?.state.arrange?.translation = .zero
            } completion: {
                // Only clear if this is still the settling session — a new
                // drag may have started while it was animating.
                if self?.state.arrange?.isSettling == true {
                    self?.state.arrange = nil
                }
            }
        }
    }

    /// Pin every tile to the cells it is sitting in, at the size packing
    /// actually used. Fitted spans and packed slots only live on the
    /// current board until this writes them — the next arrange would
    /// otherwise ask for the declared size, miss the cell, and bounce.
    func commitBoard() {
        let board = BoardArrangement(settings: settings, library: library)
        settings.commit(board.placements)
    }

    func evictOverlaps(of target: WidgetPlacement, excluding id: String) {
        for other in BoardArrangement(settings: settings, library: library).widgets
        where other.id != id {
            guard let existing = settings.position(for: other.id) else { continue }
            let occupied = WidgetPlacement(
                slot: existing,
                span: settings.span(for: other.id, declared: other.span)
            )
            if occupied.overlaps(target) { settings.clearPosition(for: other.id) }
        }
    }

    func presentDragPreview(on screen: NSScreen) {
        let preview = dragPreview ?? makeDragPreviewPanel()
        if dragPreview == nil {
            let hosting = ClearHostingView(
                rootView: WidgetDragPreview(
                    state: state,
                    library: library,
                    nowPlaying: nowPlaying
                )
            )
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.autoresizingMask = [.width, .height]
            preview.contentView = hosting
            dragPreview = preview
        }
        positionDragPreview(on: screen)
        preview.orderFrontRegardless()
    }

    func positionDragPreview(on screen: NSScreen) {
        guard let session = state.arrange, session.kind == .move, let preview = dragPreview else {
            return
        }
        let boardRect = session.originRect.offsetBy(
            dx: session.translation.width,
            dy: session.translation.height
        )
        let tile = geometry(on: screen).screenRect(from: boardRect)
        preview.setFrame(tile.insetBy(dx: -WidgetDragPreview.margin, dy: -WidgetDragPreview.margin), display: true)
    }

    func dismissDragPreview() {
        dragPreview?.orderOut(nil)
    }

    func makeDragPreviewPanel() -> NSPanel {
        let preview = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        preview.isFloatingPanel = true
        preview.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        preview.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        preview.backgroundColor = .clear
        preview.isOpaque = false
        preview.hasShadow = false
        preview.ignoresMouseEvents = true
        preview.hidesOnDeactivate = false
        preview.isReleasedWhenClosed = false
        preview.animationBehavior = .none
        return preview
    }

    func syncRemoveCursor(_ removing: Bool) {
        if removing, !didPushRemoveCursor {
            NSCursor.disappearingItem.push()
            didPushRemoveCursor = true
        } else if !removing {
            popRemoveCursor()
        }
    }

    func popRemoveCursor() {
        guard didPushRemoveCursor else { return }
        NSCursor.pop()
        didPushRemoveCursor = false
    }

    func syncPanelCursor(_ resizing: Bool) {
        if resizing, !didPushPanelCursor {
            panelResizeCursor.push()
            didPushPanelCursor = true
        } else if !resizing {
            popPanelCursor()
        }
    }

    func popPanelCursor() {
        guard didPushPanelCursor else { return }
        NSCursor.pop()
        didPushPanelCursor = false
    }

    var panelResizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            NSCursor.frameResize(position: .bottomRight, directions: .all)
        } else {
            NSCursor.crosshair
        }
    }

    /// The Dock's own "poof item off dock" UI sound. Loaded from the system
    /// catalog rather than a magic id, so it still plays if Apple reshuffles
    /// the undocumented sound numbers — and it stays silent when the user has
    /// interface sound effects switched off.
    func playDockPoof() {
        let path = """
            /System/Library/Components/CoreAudio.component\
            /Contents/SharedSupport/SystemSounds/dock/poof item off dock.aif
            """
        let url = URL(fileURLWithPath: path) as CFURL
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url, &sound) == noErr, sound != 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(sound) {
            AudioServicesDisposeSystemSoundID(sound)
        }
    }
}

/// `NSHostingView` otherwise fills with the window background, which would
/// put a grey card around a tile that is supposed to be floating on its own.
private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
}
