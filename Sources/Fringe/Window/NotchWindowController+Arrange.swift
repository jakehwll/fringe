import AppKit
import SwiftUI

@MainActor
extension NotchWindowController {
    // MARK: - Arranging
    //
    // Move and resize are driven from here rather than from SwiftUI gestures.
    // A non-activating panel delivers gestures inconsistently — hover arrives
    // because tracking areas do not need key status, drags frequently do not —
    // and the pointer monitor already backing island hover and play/pause is
    // reliable.

    /// Board coordinates (top-left origin, y down) for a point on screen.
    func boardPoint(from location: NSPoint, on screen: NSScreen) -> CGPoint {
        geometry(on: screen).boardPoint(from: location)
    }

    var isArranging: Bool { state.isExpanded && state.isEditing }

    func updateArrangeHover(at location: NSPoint, on screen: NSScreen) {
        let overPanelGrip = isArranging
            && state.arrange == nil
            && state.panelResize == nil
            && isOnPanelGrip(location, on: screen)
        state.hoveredPanelGrip = overPanelGrip
        syncPanelCursor(overPanelGrip)

        guard isArranging, state.arrange == nil else { return }

        let board = BoardArrangement(settings: settings, library: library)
        let point = boardPoint(from: location, on: screen)
        state.hoveredWidget = board.widget(at: point)
        state.hoveredGrip = board.grip(at: point)
        state.hoveredRemove = board.removeBadge(at: point)
    }

    /// The panel's own corner, in the padding outside the board so a
    /// bottom-right widget still owns its tile grip.
    func isOnPanelGrip(_ location: NSPoint, on screen: NSScreen) -> Bool {
        guard panelGripRect(on: screen).contains(location) else { return false }
        let board = geometry(on: screen).screenRect(
            from: CGRect(origin: .zero, size: settings.grid.contentSize)
        )
        return !board.contains(location)
    }

    func panelGripRect(on screen: NSScreen) -> NSRect {
        let panel = geometry(on: screen).topCentred(
            settings.expandedSize(notch: state.metrics.size)
        )
        let grip = BoardArrangement.gripSize
        return NSRect(
            x: panel.maxX - grip,
            y: panel.minY,
            width: grip,
            height: grip
        )
    }

    func beginPanelResize(at location: NSPoint, on screen: NSScreen) -> Bool {
        guard isOnPanelGrip(location, on: screen) else { return false }
        state.panelResize = NotchState.PanelResizeSession(
            startPoint: location,
            columns: settings.columns,
            rows: settings.rows
        )
        syncPanelCursor(true)
        return true
    }

    func updatePanelResize(at location: NSPoint, on screen: NSScreen) {
        guard let session = state.panelResize else { return }
        // Screen y goes up; a downward drag should add rows.
        let translation = CGSize(
            width: location.x - session.startPoint.x,
            height: session.startPoint.y - location.y
        )
        let next = settings.grid.grown(
            from: session.columns,
            rows: session.rows,
            by: translation,
            columnRange: NotchSettings.columnRange,
            rowRange: NotchSettings.rowRange
        )
        guard next.columns != settings.columns || next.rows != settings.rows else { return }
        settings.columns = next.columns
        settings.rows = next.rows
        library.render(placements: BoardArrangement(settings: settings, library: library).placements)
    }

    func endPanelResize() {
        commitBoard()
        state.panelResize = nil
        state.hoveredPanelGrip = false
        syncPanelCursor(false)
    }

    func beginArrange(at location: NSPoint, on screen: NSScreen) {
        let board = BoardArrangement(settings: settings, library: library)
        let point = boardPoint(from: location, on: screen)

        // Minus first: it sits inside the tile, so a move would otherwise
        // swallow the tap. Grip next, for the same reason.
        if let id = board.removeBadge(at: point) {
            hideWidget(id)
            return
        }

        let kind: NotchState.ArrangeSession.Kind
        let id: String
        if let grip = board.grip(at: point) {
            kind = .resize
            id = grip
        } else if let widget = board.widget(at: point) {
            kind = .move
            id = widget
        } else {
            return
        }

        guard let placement = board.placements[id], let rect = board.rect(of: id) else { return }

        state.arrange = NotchState.ArrangeSession(
            widgetID: id,
            kind: kind,
            startPoint: point,
            originRect: rect,
            originSlot: placement.slot,
            baseSpan: placement.span,
            landing: placement
        )
        if kind == .move {
            presentDragPreview(on: screen)
        }
    }

    func updateArrange(at location: NSPoint, on screen: NSScreen) {
        // A settling session is mid-animation and its start point no longer
        // relates to where the tile now lives; recomputing against it throws
        // the tile off in a wrong direction.
        guard var session = state.arrange, !session.isSettling else { return }

        let grid = settings.grid
        let point = boardPoint(from: location, on: screen)
        let delta = CGSize(
            width: point.x - session.startPoint.x,
            height: point.y - session.startPoint.y
        )

        let landing = proposedLanding(
            for: session,
            delta: delta,
            at: location,
            on: screen,
            grid: grid
        )

        let landingChanged = session.landing != landing.placement
        session.translation = delta
        session.isRemoving = landing.offPanel
        // Pointer tracking stays unanimated. Landing updates in a second
        // write so neighbours can spring into the hole drop will make.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { state.arrange = session }
        if session.kind == .move {
            syncRemoveCursor(landing.offPanel)
            positionDragPreview(on: screen)
        }

        if landingChanged {
            session.landing = landing.placement
            if session.kind == .resize, let next = landing.placement {
                library.render(id: session.widgetID, span: next.span)
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                state.arrange = session
            }
        }
    }

    private func proposedLanding(
        for session: NotchState.ArrangeSession,
        delta: CGSize,
        at location: NSPoint,
        on screen: NSScreen,
        grid: NotchGrid
    ) -> (placement: WidgetPlacement?, offPanel: Bool) {
        switch session.kind {
        case .move:
            let dropped = CGPoint(
                x: session.originRect.minX + delta.width,
                y: session.originRect.minY + delta.height
            )
            let snapped = WidgetPlacement(
                slot: grid.slot(snapping: dropped, span: session.baseSpan),
                span: session.baseSpan
            )
            let offPanel = geometry(on: screen).isOffPanel(
                location,
                size: settings.expandedSize(notch: state.metrics.size)
            )
            return (offPanel ? nil : snapped, offPanel)
        case .resize:
            let resized = grid.span(session.baseSpan, grownBy: delta)
            return (
                WidgetPlacement(
                    slot: grid.clampSlot(session.originSlot, span: resized),
                    span: resized
                ),
                false
            )
        }
    }

    func endArrange(at location: NSPoint) {
        guard var session = state.arrange, !session.isSettling else { return }

        guard session.kind == .move else {
            commitLanding(session)
            state.arrange = nil
            return
        }

        if let screen {
            session.isRemoving = geometry(on: screen).isOffPanel(
                location,
                size: settings.expandedSize(notch: state.metrics.size)
            )
        }
        popRemoveCursor()

        if session.isRemoving {
            removeArrangedWidget(session)
            return
        }

        dismissDragPreview()
        placeArrangedWidget(session)
    }
}
