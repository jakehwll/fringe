import AppKit

/// The app has no Dock icon, so a menu bar item is the only way to drive it by
/// hand — and, more importantly, to quit it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let windowController: NotchWindowController
    private let onOpenSettings: () -> Void

    init(windowController: NotchWindowController, onOpenSettings: @escaping () -> Void) {
        self.windowController = windowController
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "Fringe"
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(
            withTitle: "Toggle Panel",
            action: #selector(togglePanel),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.title = windowController.state.isExpanded ? "Collapse Panel" : "Expand Panel"
    }

    @objc private func togglePanel() {
        windowController.toggle()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
