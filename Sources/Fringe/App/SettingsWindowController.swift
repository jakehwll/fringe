import AppKit
import SwiftUI

/// Hosts a standard Mac preferences window: a preference-style toolbar of pane
/// icons, traffic-light close, and a content view that resizes per pane.
///
/// An accessory app has no menu bar, so ⌘W and Escape are synthesised here, and
/// the app is activated explicitly before the window can take focus.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    /// Fires when the window opens and closes, so the panel can pin itself open
    /// for as long as settings are being edited.
    var onVisibilityChange: ((Bool) -> Void)?

    private let settings: NotchSettings
    private let state: NotchState
    private let library: ScriptLibrary
    private let chrome = SettingsChrome()
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(settings: NotchSettings, state: NotchState, library: ScriptLibrary) {
        self.settings = settings
        self.state = state
        self.library = library
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // Leave a window the user has already positioned where they put it.
        if !window.isVisible {
            applyPaneSize(window)
            positionBelowPanel(window)
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        onVisibilityChange?(true)
    }

    func close() {
        window?.close()
    }

    /// Hangs the window under the expanded panel instead of centring it on screen.
    /// The panel floats above the menu bar at a higher window level, so anything
    /// overlapping it would simply be hidden behind it.
    private func positionBelowPanel(_ window: NSWindow) {
        guard let screen = NSScreen.notchHost() else {
            window.center()
            return
        }

        let size = window.frame.size
        let panelHeight = settings.expandedSize(notch: state.metrics.size).height
            + settings.windowBottomPadding
        let panelBottom = screen.frame.maxY - panelHeight
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: max(screen.visibleFrame.minY + Self.edgeGap, panelBottom - Self.edgeGap - size.height)
        )
        window.setFrameOrigin(origin)
    }

    private static let edgeGap: CGFloat = 16

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: SettingsView(
                chrome: chrome,
                settings: settings,
                library: library,
                state: state
            )
        )

        let window = NSWindow(contentViewController: controller)
        window.title = chrome.pane.title
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.delegate = self
        // Above the notch panel, otherwise the panel's transparent hit area
        // swallows the traffic-light buttons.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = chrome.pane.toolbarIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        applyPaneSize(window)
        installKeyMonitor()
        return window
    }

    private func applyPaneSize(_ window: NSWindow) {
        window.setContentSize(
            NSSize(width: SettingsPane.contentWidth, height: chrome.pane.contentHeight)
        )
        window.title = chrome.pane.title
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(toolbarIdentifier: itemIdentifier) else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.image = NSImage(
            systemSymbolName: pane.symbolName,
            accessibilityDescription: pane.title
        )
        item.isBordered = false
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(toolbarIdentifier: sender.itemIdentifier) else { return }
        chrome.pane = pane
        window?.toolbar?.selectedItemIdentifier = pane.toolbarIdentifier
        if let window {
            let origin = window.frame.origin
            let top = window.frame.maxY
            applyPaneSize(window)
            // Keep the title bar where it is while the content grows or shrinks,
            // which is how every Mac preferences window behaves.
            var frame = window.frame
            frame.origin = NSPoint(x: origin.x, y: top - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    /// Without a main menu there is no ⌘W, so synthesise it along with Escape.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isClose = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers == "w"
            let isEscape = event.keyCode == 53
            guard isClose || isEscape else { return event }

            // `assumeIsolated` can only hand back a Sendable value, and NSEvent is
            // not one, so decide here and swallow the event outside.
            let didClose = MainActor.assumeIsolated { () -> Bool in
                guard let window = self?.window, window.isKeyWindow else { return false }
                window.close()
                return true
            }
            return didClose ? nil : event
        }
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}
