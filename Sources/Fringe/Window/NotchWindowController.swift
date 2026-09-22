import AppKit
import AudioToolbox
import SwiftUI

/// AppKit splits app-level and workspace-level notifications across two centres.
enum NotificationCenterSource {
    case `default`
    case workspace

    @MainActor
    var center: NotificationCenter {
        switch self {
        case .default: NotificationCenter.default
        case .workspace: NSWorkspace.shared.notificationCenter
        }
    }
}

/// Owns the panel, keeps it glued to the top-centre of the notch display, and
/// drives hover peek plus click-to-open. The expanded panel still closes when
/// the pointer leaves.
@MainActor
final class NotchWindowController {
    let state: NotchState
    private let settings: NotchSettings

    private var panel: NotchPanel?
    private var screen: NSScreen?
    private var mouseTracker: MouseTracker?
    private var pendingTransition: DispatchWorkItem?
    /// Follows the cursor while a tile is lifted, so the widget can leave the
    /// clipped silhouette the way a Dock icon leaves the Dock.
    private var dragPreview: NSPanel?
    private var didPushRemoveCursor = false
    private var didPushPanelCursor = false
    private let library: ScriptLibrary
    private let nowPlaying: NowPlayingController
    private let battery: BatteryMonitor
    private let onOpenSettings: () -> Void

    init(
        state: NotchState,
        settings: NotchSettings,
        library: ScriptLibrary,
        nowPlaying: NowPlayingController,
        battery: BatteryMonitor,
        onOpenSettings: @escaping () -> Void
    ) {
        self.state = state
        self.settings = settings
        self.library = library
        self.nowPlaying = nowPlaying
        self.battery = battery
        self.onOpenSettings = onOpenSettings
    }

    // MARK: - Lifecycle

    func start() {
        install()

        let tracker = MouseTracker(
            onMove: { [weak self] location in
                self?.pointerMoved(to: location)
            },
            onPress: { [weak self] location in
                self?.pointerPressed(at: location)
            },
            onRelease: { [weak self] location in
                self?.pointerReleased(at: location)
            }
        )
        tracker.start()
        mouseTracker = tracker

        library.islandContext = { [weak self] in
            guard let self else { return .zero }
            let layout = self.settings.islandLayout(notch: self.state.metrics.size)
            return IslandScriptContext(
                pulse: self.battery.pulse,
                hover: self.state.isHovered,
                side: layout.contentSide,
                wing: layout.wingWidth
            )
        }
        library.refreshIslands()
        trackIsland()

        // Displays coming and going, or the machine waking, can invalidate both the
        // panel's frame and the notch measurements.
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { $0.install() }
        observe(NSWorkspace.didWakeNotification, on: .workspace) { $0.install() }
        // Spaces do not move the panel, but they can push it behind other windows.
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: .workspace) {
            $0.panel?.orderFrontRegardless()
        }

        trackEditing()
        trackBoard()
    }

    private func trackEditing() {
        withObservationTracking {
            _ = state.isEditing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.state.isEditing {
                    self.endPanelResize()
                }
                self.trackEditing()
            }
        }
    }

    /// Grid size and who is on the board change packing. Persist the cells
    /// that actually got used once the change has settled — not mid-drag,
    /// or neighbours get pinned into holes that only exist for a frame.
    private func trackBoard() {
        withObservationTracking {
            _ = settings.columns
            _ = settings.rows
            _ = settings.disabledWidgets
            _ = library.widgets.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.state.panelResize == nil, self.state.arrange == nil {
                    self.commitBoard()
                }
                self.trackBoard()
            }
        }
    }

    /// Pulse, hover, media, and enabled-widgets all change who owns the wings
    /// without a file save, so they force `island()` rather than waiting out
    /// a widget's refresh interval.
    private func trackIsland() {
        withObservationTracking {
            _ = battery.pulse
            _ = battery.snapshot?.percent
            _ = nowPlaying.snapshot?.isPlaying
            _ = state.isHovered
            _ = state.metrics
            _ = settings.disabledWidgets
            _ = library.widgets.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.library.refreshIslands(force: true)
                self.trackIsland()
            }
        }
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenterSource,
        handler: @escaping @Sendable @MainActor (NotchWindowController) -> Void
    ) {
        center.center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    // MARK: - Panel construction

    /// Creates the panel if needed, then re-measures and re-places it. Safe to call
    /// repeatedly — this is also the recovery path when the display setup changes.
    private func install() {
        guard let screen = NSScreen.notchHost() else {
            // Every display went away (clamshell, for instance). Park the panel
            // until one comes back.
            setMode(.collapsed)
            panel?.orderOut(nil)
            self.screen = nil
            return
        }

        self.screen = screen
        state.metrics = NotchMetrics.resolve(for: screen, settings: settings)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(windowFrame(on: screen), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero)
        let hostingView = NSHostingView(
            rootView: NotchRootView(
                state: state,
                settings: settings,
                library: library,
                nowPlaying: nowPlaying,
                onOpenSettings: onOpenSettings
            )
        )
        hostingView.autoresizingMask = [.width, .height]

        let hitView = NotchHitView()
        hostingView.frame = hitView.bounds
        hitView.addSubview(hostingView)
        hitView.isPointHittable = { [weak self] point in
            self?.isHittable(at: point) ?? false
        }
        panel.contentView = hitView
        return panel
    }

    /// A fixed window big enough for the largest expanded panel plus shadow
    /// margin, hung from the very top of the screen. Grid resizes animate the
    /// silhouette path inside this canvas so the window origin never moves.
    private func windowFrame(on screen: NSScreen) -> NSRect {
        geometry(on: screen).topCentred(settings.windowOuterSize(notch: state.metrics.size))
    }

    /// The panel's placement on a screen, as a pure value. Everything that
    /// needs a rect or a coordinate conversion goes through this rather than
    /// doing the midX/maxY arithmetic again by hand.
    private func geometry(on screen: NSScreen) -> PanelGeometry {
        PanelGeometry(
            screenFrame: screen.frame,
            notchHeight: state.metrics.size.height,
            contentTopPadding: settings.contentTopPadding,
            boardSize: settings.grid.contentSize
        )
    }

    // MARK: - Pointer handling

    private func pointerMoved(to location: NSPoint) {
        guard let screen else { return }

        if state.panelResize != nil {
            updatePanelResize(at: location, on: screen)
            return
        }
        if state.arrange != nil {
            updateArrange(at: location, on: screen)
            return
        }
        updateArrangeHover(at: location, on: screen)

        switch state.mode {
        case .collapsed:
            setHovered(collapsedHotZone(on: screen).contains(location))
        case .expanded:
            // Arranging drags routinely leave the panel's bounds; collapsing
            // mid-drag would drop the widget.
            if state.isPinned || state.isEditing || expandedHotZone(on: screen).contains(location)
            {
                cancelPendingTransition()
            } else {
                scheduleTransition(to: .collapsed, after: settings.collapseDelay)
            }
        }
    }

    // MARK: - Arranging
    //
    // Move and resize are driven from here rather than from SwiftUI gestures.
    // A non-activating panel delivers gestures inconsistently — hover arrives
    // because tracking areas do not need key status, drags frequently do not —
    // and the pointer monitor already backing island hover and play/pause is
    // reliable.

    /// Board coordinates (top-left origin, y down) for a point on screen.
    private func boardPoint(from location: NSPoint, on screen: NSScreen) -> CGPoint {
        geometry(on: screen).boardPoint(from: location)
    }

    private var isArranging: Bool { state.isExpanded && state.isEditing }

    private func updateArrangeHover(at location: NSPoint, on screen: NSScreen) {
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
    private func isOnPanelGrip(_ location: NSPoint, on screen: NSScreen) -> Bool {
        guard panelGripRect(on: screen).contains(location) else { return false }
        let board = geometry(on: screen).screenRect(
            from: CGRect(origin: .zero, size: settings.grid.contentSize)
        )
        return !board.contains(location)
    }

    private func panelGripRect(on screen: NSScreen) -> NSRect {
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

    private func beginPanelResize(at location: NSPoint, on screen: NSScreen) -> Bool {
        guard isOnPanelGrip(location, on: screen) else { return false }
        state.panelResize = NotchState.PanelResizeSession(
            startPoint: location,
            columns: settings.columns,
            rows: settings.rows
        )
        syncPanelCursor(true)
        return true
    }

    private func updatePanelResize(at location: NSPoint, on screen: NSScreen) {
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

    private func endPanelResize() {
        commitBoard()
        state.panelResize = nil
        state.hoveredPanelGrip = false
        syncPanelCursor(false)
    }

    private func beginArrange(at location: NSPoint, on screen: NSScreen) {
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

    private func updateArrange(at location: NSPoint, on screen: NSScreen) {
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

        let landing: WidgetPlacement?
        let offPanel: Bool
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
            offPanel = geometry(on: screen).isOffPanel(
                location,
                size: settings.expandedSize(notch: state.metrics.size)
            )
            landing = offPanel ? nil : snapped
        case .resize:
            let resized = grid.span(session.baseSpan, grownBy: delta)
            landing = WidgetPlacement(
                slot: grid.clampSlot(session.originSlot, span: resized),
                span: resized
            )
            offPanel = false
        }

        let landingChanged = session.landing != landing
        session.translation = delta
        session.isRemoving = offPanel
        // Pointer tracking stays unanimated. Landing updates in a second
        // write so neighbours can spring into the hole drop will make.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { state.arrange = session }
        if session.kind == .move {
            syncRemoveCursor(offPanel)
            positionDragPreview(on: screen)
        }

        if landingChanged {
            session.landing = landing
            if session.kind == .resize, let next = landing {
                library.render(id: session.widgetID, span: next.span)
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                state.arrange = session
            }
        }
    }

    private func endArrange(at location: NSPoint) {
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

    /// Hide, don't delete: the script stays on disk and in the settings list,
    /// matching the Dock (the app is not in the trash, just off the strip).
    private func hideWidget(_ id: String) {
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

    private func removeArrangedWidget(_ session: NotchState.ArrangeSession) {
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
    private func commitLanding(_ session: NotchState.ArrangeSession) {
        guard let target = session.landing else {
            commitBoard()
            return
        }
        evictOverlaps(of: target, excluding: session.widgetID)
        settings.setSpan(target.span, for: session.widgetID)
        settings.setPosition(target.slot, for: session.widgetID)
        commitBoard()
    }

    private func placeArrangedWidget(_ session: NotchState.ArrangeSession) {
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
    private func commitBoard() {
        let board = BoardArrangement(settings: settings, library: library)
        settings.commit(board.placements)
    }

    private func evictOverlaps(of target: WidgetPlacement, excluding id: String) {
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

    private func presentDragPreview(on screen: NSScreen) {
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

    private func positionDragPreview(on screen: NSScreen) {
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

    private func dismissDragPreview() {
        dragPreview?.orderOut(nil)
    }

    private func makeDragPreviewPanel() -> NSPanel {
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

    private func syncRemoveCursor(_ removing: Bool) {
        if removing, !didPushRemoveCursor {
            NSCursor.disappearingItem.push()
            didPushRemoveCursor = true
        } else if !removing {
            popRemoveCursor()
        }
    }

    private func popRemoveCursor() {
        guard didPushRemoveCursor else { return }
        NSCursor.pop()
        didPushRemoveCursor = false
    }

    private func syncPanelCursor(_ resizing: Bool) {
        if resizing, !didPushPanelCursor {
            panelResizeCursor.push()
            didPushPanelCursor = true
        } else if !resizing {
            popPanelCursor()
        }
    }

    private func popPanelCursor() {
        guard didPushPanelCursor else { return }
        NSCursor.pop()
        didPushPanelCursor = false
    }

    private var panelResizeCursor: NSCursor {
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
    private func playDockPoof() {
        let url = URL(
            fileURLWithPath:
                "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/poof item off dock.aif"
        ) as CFURL
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url, &sound) == noErr, sound != 0 else { return }
        AudioServicesPlaySystemSoundWithCompletion(sound) {
            AudioServicesDisposeSystemSoundID(sound)
        }
    }

    private func pointerReleased(at location: NSPoint) {
        if state.panelResize != nil {
            endPanelResize()
            return
        }
        endArrange(at: location)
    }

    private func pointerPressed(at location: NSPoint) {
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
    private func mediaToggleHotZone(on screen: NSScreen) -> NSRect? {
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

    private func collapsedHotZone(on screen: NSScreen) -> NSRect {
        // Use the peeked size so the grown region stays inside the hot zone,
        // and so the rest-state island is a little easier to hit from below.
        let size = settings.peekSize(
            notch: state.metrics.size,
            hasWings: library.occupancy != nil
        )
        return geometry(on: screen).hotZone(size, horizontal: settings.collapsedHoverPadding)
    }

    private func isHittable(at location: NSPoint) -> Bool {
        guard let screen else { return false }
        if state.isExpanded {
            let size = settings.expandedSize(notch: state.metrics.size)
            return geometry(on: screen).topCentred(size).contains(location)
        }
        return collapsedHotZone(on: screen).contains(location)
    }

    private func expandedHotZone(on screen: NSScreen) -> NSRect {
        let padding = settings.expandedHoverPadding
        return geometry(on: screen).hotZone(
            settings.expandedSize(notch: state.metrics.size),
            horizontal: padding,
            bottom: padding
        )
    }

    private func scheduleTransition(to mode: NotchState.Mode, after delay: TimeInterval) {
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

    private func cancelPendingTransition() {
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

    private func setHovered(_ hovered: Bool) {
        guard state.isHovered != hovered else { return }
        state.isHovered = hovered
    }

    private func syncHover() {
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
