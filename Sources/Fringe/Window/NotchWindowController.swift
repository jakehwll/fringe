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
    let settings: NotchSettings

    var panel: NotchPanel?
    var screen: NSScreen?
    var mouseTracker: MouseTracker?
    var pendingTransition: DispatchWorkItem?
    /// Follows the cursor while a tile is lifted, so the widget can leave the
    /// clipped silhouette the way a Dock icon leaves the Dock.
    var dragPreview: NSPanel?
    var didPushRemoveCursor = false
    var didPushPanelCursor = false
    let library: ScriptLibrary
    let nowPlaying: NowPlayingController
    let battery: BatteryMonitor
    let onOpenSettings: () -> Void

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

    func trackEditing() {
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
    func trackBoard() {
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
    func trackIsland() {
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

    func observe(
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
    func install() {
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

    func makePanel() -> NotchPanel {
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
    func windowFrame(on screen: NSScreen) -> NSRect {
        geometry(on: screen).topCentred(settings.windowOuterSize(notch: state.metrics.size))
    }

    /// The panel's placement on a screen, as a pure value. Everything that
    /// needs a rect or a coordinate conversion goes through this rather than
    /// doing the midX/maxY arithmetic again by hand.
    func geometry(on screen: NSScreen) -> PanelGeometry {
        PanelGeometry(
            screenFrame: screen.frame,
            notchHeight: state.metrics.size.height,
            contentTopPadding: settings.contentTopPadding,
            boardSize: settings.grid.contentSize
        )
    }

    // MARK: - Pointer handling

    func pointerMoved(to location: NSPoint) {
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
            if state.isPinned || state.isEditing || expandedHotZone(on: screen).contains(location) {
                cancelPendingTransition()
            } else {
                scheduleTransition(to: .collapsed, after: settings.collapseDelay)
            }
        }
    }
}
