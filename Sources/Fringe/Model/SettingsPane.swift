import AppKit

/// The toolbar tabs in the settings window. One pane, one toolbar item — the
/// same pattern as Safari, Xcode, and every other Mac preferences window.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case grid
    case widgets
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .grid: "Grid"
        case .widgets: "Widgets"
        case .debug: "Debug"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .grid: "square.grid.2x2"
        case .widgets: "curlybraces.square"
        case .debug: "stethoscope"
        }
    }

    /// Content-view height for this pane. Preference windows resize when you
    /// switch tabs; they do not scroll a single giant form.
    var contentHeight: CGFloat {
        switch self {
        case .general: 320
        case .grid: 312
        case .widgets: 500
        case .debug: 420
        }
    }

    static let contentWidth: CGFloat = 480

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.\(rawValue)")
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        let prefix = "settings."
        let raw = toolbarIdentifier.rawValue
        guard raw.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(raw.dropFirst(prefix.count)))
    }
}

@MainActor
@Observable
final class SettingsChrome {
    var pane: SettingsPane = .general
}
